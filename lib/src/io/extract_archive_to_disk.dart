import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_entry.dart';
import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip_decoder.dart';
import '../util/input_stream.dart';
import '../util/input_file_stream.dart';
import '../util/output_file_stream.dart';

/// Ensure filePath is contained in the outputDir folder, to make sure archives
/// aren't trying to write to some system path.
bool isWithinOutputPath(String outputDir, String filePath) {
  return path.isWithin(
      path.canonicalize(outputDir), path.canonicalize(filePath));
}

bool _isValidSymLink(String outputPath, ArchiveEntry file) {
  final filePath =
      path.dirname(path.join(outputPath, path.normalize(file.name)));
  final linkPath = path.normalize(file.symbolicLink ?? "");
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  final absLinkPath = path.normalize(path.join(filePath, linkPath));
  if (!isWithinOutputPath(outputPath, absLinkPath)) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  return true;
}

void _prepareOutDir(String outDirPath) {
  final outDir = Directory(outDirPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
}

String? _prepareArchiveFilePath(ArchiveFile archiveFile, String outputPath) {
  final filePath = path.join(outputPath, path.normalize(archiveFile.name));

  if ((!archiveFile.isFile && !archiveFile.isSymbolicLink) ||
      !isWithinOutputPath(outputPath, filePath)) {
    return null;
  }

  if (archiveFile.isSymbolicLink) {
    if (!_isValidSymLink(outputPath, archiveFile)) {
      return null;
    }
  }

  return filePath;
}

void _extractArchiveEntryToDiskSync(
  ArchiveFile file,
  String filePath, {
  int? bufferSize,
}) {
  if (file.isSymbolicLink) {
    final link = Link(filePath);
    link.createSync(path.normalize(file.symbolicLink ?? ""), recursive: true);
  } else {
    final output = OutputFileStream(filePath, bufferSize: bufferSize);
    try {
      file.writeContent(output);
    } catch (err) {
      //
    }
    output.closeSync();
  }
}

void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
}) {
  _prepareOutDir(outputPath);
  final files = archive.getAllFiles();
  for (final file in files) {
    final filePath = _prepareArchiveFilePath(file, outputPath);
    if (filePath != null) {
      _extractArchiveEntryToDiskSync(file, filePath, bufferSize: bufferSize);
    }
  }
}

Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {bool asyncWrite = true, int? bufferSize}) async {
  final futures = <Future<void>>[];
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
  final entries = archive.getAllEntries();
  for (final entry in entries) {
    final filePath = path.normalize(path.join(outputPath, entry.fullPathName));

    if ((!entry.isFile && !entry.isSymbolicLink) ||
        !isWithinOutputPath(outputPath, filePath)) {
      continue;
    }

    if (entry.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, entry)) {
        continue;
      }

      if (asyncWrite) {
        final link = Link(filePath);
        await link.create(path.normalize(entry.symbolicLink ?? ""),
            recursive: true);
      } else {
        final link = Link(filePath);
        link.createSync(path.normalize(entry.symbolicLink ?? ""),
            recursive: true);
      }
      continue;
    }

    if (!entry.isFile) {
      if (asyncWrite) {
        await Directory(filePath).create(recursive: true);
      } else {
        Directory(filePath).createSync(recursive: true);
      }
      continue;
    }

    ArchiveFile file = entry as ArchiveFile;

    /*if (asyncWrite) {
      final output = File(filePath);
      final f = await output.create(recursive: true);
      final fp = await f.open(mode: FileMode.write);
      final bytes = file.readBytes()!;
      await fp.writeFrom(bytes);
      await file.clear();
      futures.add(fp.close());
    } else {*/
    bufferSize ??= OutputFileStream.kDefaultBufferSize;
    final fileSize = file.size;
    final fileBufferSize = fileSize < bufferSize ? fileSize : bufferSize;
    final output = OutputFileStream(filePath, bufferSize: fileBufferSize);
    try {
      file.writeContent(output);
    } catch (err) {
      //
    }
    await output.close();
  }
  //}
  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }
}

Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password, bool asyncWrite = false, int? bufferSize}) async {
  Directory? tempDir;
  var archivePath = inputPath;

  var futures = <Future<void>>[];
  if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = path.join(tempDir.path, 'temp.tar');
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath, bufferSize: bufferSize);
    GZipDecoder().decodeStream(input, output);
    futures.add(input.close());
    futures.add(output.close());
  } else if (inputPath.endsWith('tar.bz2') || inputPath.endsWith('tbz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = path.join(tempDir.path, 'temp.tar');
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath, bufferSize: bufferSize);
    BZip2Decoder().decodeStream(input, output);
    futures.add(input.close());
    futures.add(output.close());
  } else if (inputPath.endsWith('tar.xz') || inputPath.endsWith('txz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = path.join(tempDir.path, 'temp.tar');
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath, bufferSize: bufferSize);
    output.writeBytes(XZDecoder().decodeStream(input));
    futures.add(input.close());
    futures.add(output.close());
  }

  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }

  InputStream? toClose;

  Archive archive;
  if (archivePath.endsWith('tar')) {
    final input = InputFileStream(archivePath);
    archive = TarDecoder().decodeStream(input);
    toClose = input;
  } else if (archivePath.endsWith('zip')) {
    final input = InputFileStream(archivePath);
    archive = ZipDecoder().decodeStream(input, password: password);
    toClose = input;
  } else {
    throw ArgumentError.value(inputPath, 'inputPath',
        'Must end tar.gz, tgz, tar.bz2, tbz, tar.xz, txz, tar or zip.');
  }

  final files = archive.getAllFiles();
  for (final file in files) {
    final filePath = path.join(outputPath, path.normalize(file.name));
    if (!isWithinOutputPath(outputPath, filePath)) {
      continue;
    }

    if (file.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, file)) {
        continue;
      }
    }

    if (!file.isFile && !file.isSymbolicLink) {
      Directory(filePath).createSync(recursive: true);
      continue;
    }

    if (asyncWrite) {
      if (file.isSymbolicLink) {
        final link = Link(filePath);
        await link.create(path.normalize(file.symbolicLink ?? ""),
            recursive: true);
      } else {
        final output = File(filePath);
        final f = await output.create(recursive: true);
        final fp = await f.open(mode: FileMode.write);
        final bytes = file.readBytes()!;
        await fp.writeFrom(bytes);
        await file.clear();
        futures.add(fp.close());
      }
    } else {
      if (file.isSymbolicLink) {
        final link = Link(filePath);
        final p = path.normalize(file.symbolicLink ?? "");
        link.createSync(p, recursive: true);
      } else {
        final output = OutputFileStream(filePath, bufferSize: bufferSize);
        try {
          file.writeContent(output);
        } catch (err) {
          //
        }
        futures.add(output.close());
      }
    }
  }

  futures.add(toClose.close());

  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }

  futures.add(archive.clear());

  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }

  if (tempDir != null) {
    futures.add(tempDir.delete(recursive: true));
  }

  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive.dart';
import '../archive_file.dart';
import '../bzip2_decoder.dart';
import '../gzip_decoder.dart';
import '../tar_decoder.dart';
import '../util/input_stream.dart';
import '../xz_decoder.dart';
import '../zip_decoder.dart';
import 'input_file_stream.dart';
import 'output_file_stream.dart';

/// Ensure filePath is contained in the outputDir folder, to make sure archives
/// aren't trying to write to some system path.
bool isWithinOutputPath(String outputDir, String filePath) {
  return path.isWithin(
      path.canonicalize(outputDir), path.canonicalize(filePath));
}

bool _isValidSymLink(String outputPath, ArchiveFile file) {
  final filePath =
      path.dirname(path.join(outputPath, path.normalize(file.name)));
  final linkPath = path.normalize(file.nameOfLinkedFile);
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

Future<void> _extractArchiveEntryToDisk(
    ArchiveFile file, String filePath) async {
  if (file.isSymbolicLink) {
    final link = Link(filePath);
    await link.create(
      path.normalize(file.nameOfLinkedFile),
      recursive: true,
    );
  } else {
    final output = File(filePath);
    final f = await output.create(recursive: true);
    final fp = await f.open(mode: FileMode.write);
    final bytes = file.content as List<int>;
    final fp2 = await fp.writeFrom(bytes);
    file.clear();
    await fp2.close();
  }
}

Future<void> extractArchiveToDisk(
  Archive archive,
  String outputPath, {
  int? bufferSize,
}) async {
  _prepareOutDir(outputPath);
  for (final file in archive.files) {
    final filePath = _prepareArchiveFilePath(file, outputPath);
    if (filePath != null) {
      await _extractArchiveEntryToDisk(file, filePath);
    }
  }
}

void _extractArchiveEntryToDiskSync(
  ArchiveFile file,
  String filePath, {
  int? bufferSize,
}) {
  if (file.isSymbolicLink) {
    final link = Link(filePath);
    link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
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
  for (final file in archive.files) {
    final filePath = _prepareArchiveFilePath(file, outputPath);
    if (filePath != null) {
      _extractArchiveEntryToDiskSync(file, filePath, bufferSize: bufferSize);
    }
  }
}

Future<void> extractArchiveToDiskAsync(Archive archive, String outputPath,
    {bool asyncWrite = false, int? bufferSize}) async {
  final futures = <Future<void>>[];
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
  for (final file in archive.files) {
    final filePath = path.join(outputPath, path.normalize(file.name));

    if ((!file.isFile && !file.isSymbolicLink) ||
        !isWithinOutputPath(outputPath, filePath)) {
      continue;
    }

    if (file.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, file)) {
        continue;
      }
    }

    if (asyncWrite) {
      if (file.isSymbolicLink) {
        final link = Link(filePath);
        await link.create(path.normalize(file.nameOfLinkedFile),
            recursive: true);
      } else {
        final output = File(filePath);
        final f = await output.create(recursive: true);
        final fp = await f.open(mode: FileMode.write);
        final bytes = file.content as List<int>;
        await fp.writeFrom(bytes);
        file.clear();
        futures.add(fp.close());
      }
    } else {
      if (file.isSymbolicLink) {
        final link = Link(filePath);
        link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
      } else {
        final output = OutputFileStream(filePath, bufferSize: bufferSize);
        try {
          file.writeContent(output);
        } catch (err) {
          //
        }
        await output.close();
      }
    }
  }
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
    BZip2Decoder().decodeBuffer(input, output: output);
    futures.add(input.close());
    futures.add(output.close());
  } else if (inputPath.endsWith('tar.xz') || inputPath.endsWith('txz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = path.join(tempDir.path, 'temp.tar');
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath, bufferSize: bufferSize);
    output.writeBytes(XZDecoder().decodeBuffer(input));
    futures.add(input.close());
    futures.add(output.close());
  }

  if (futures.isNotEmpty) {
    await Future.wait(futures);
    futures.clear();
  }

  InputStreamBase? toClose;

  Archive archive;
  if (archivePath.endsWith('tar')) {
    final input = InputFileStream(archivePath);
    archive = TarDecoder().decodeBuffer(input);
    toClose = input;
  } else if (archivePath.endsWith('zip')) {
    final input = InputFileStream(archivePath);
    archive = ZipDecoder().decodeBuffer(input, password: password);
    toClose = input;
  } else {
    throw ArgumentError.value(inputPath, 'inputPath',
        'Must end tar.gz, tgz, tar.bz2, tbz, tar.xz, txz, tar or zip.');
  }

  for (final file in archive.files) {
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
        await link.create(path.normalize(file.nameOfLinkedFile),
            recursive: true);
      } else {
        final output = File(filePath);
        final f = await output.create(recursive: true);
        final fp = await f.open(mode: FileMode.write);
        final bytes = file.content as List<int>;
        await fp.writeFrom(bytes);
        file.clear();
        futures.add(fp.close());
      }
    } else {
      if (file.isSymbolicLink) {
        final link = Link(filePath);
        link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
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

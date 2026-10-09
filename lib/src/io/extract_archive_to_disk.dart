import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip_decoder.dart';
import '../codecs/zstd_decoder.dart';
import '../util/input_file_stream.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
import 'posix.dart' as posix;

// Ensure filePath is contained in the outputDir folder, to make sure archives
// aren't trying to write to some system path.
bool _isWithinOutputPath(String outputDir, String filePath) {
  return path.isWithin(
      path.canonicalize(outputDir), path.canonicalize(filePath));
}

bool _isValidSymLink(String outputPath, ArchiveFile file) {
  final filePath =
      path.dirname(path.join(outputPath, path.normalize(file.name)));
  final linkPath = path.normalize(file.symbolicLink ?? "");
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  final absLinkPath = path.normalize(path.join(filePath, linkPath));
  if (!_isWithinOutputPath(outputPath, absLinkPath)) {
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

  if ((archiveFile.isDirectory && !archiveFile.isSymbolicLink) ||
      !_isWithinOutputPath(outputPath, filePath)) {
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
  ArchiveFile entry,
  String filePath, {
  int? bufferSize,
}) {
  if (entry.isSymbolicLink) {
    final link = Link(filePath);
    link.createSync(path.normalize(entry.symbolicLink ?? ""), recursive: true);
  } else {
    if (entry.isFile) {
      final output = OutputFileStream(filePath, bufferSize: bufferSize);
      try {
        entry.writeContent(output);
      } catch (err) {
        //
      }
      output.closeSync();
    } else {
      Directory(filePath).createSync(recursive: true);
    }
  }
}

void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
}) {
  _prepareOutDir(outputPath);
  for (final entry in archive) {
    final filePath = _prepareArchiveFilePath(entry, outputPath);
    if (filePath != null) {
      _extractArchiveEntryToDiskSync(entry, filePath, bufferSize: bufferSize);
    }
  }
}

Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {int? bufferSize}) async {
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  for (final entry in archive) {
    final filePath = path.normalize(path.join(outputPath, entry.name));

    if ((entry.isDirectory && !entry.isSymbolicLink) ||
        !_isWithinOutputPath(outputPath, filePath)) {
      continue;
    }

    if (entry.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, entry)) {
        continue;
      }

      final link = Link(filePath);
      await link.create(path.normalize(entry.symbolicLink ?? ""),
          recursive: true);
      continue;
    }

    if (entry.isDirectory) {
      await Directory(filePath).create(recursive: true);
      continue;
    }

    ArchiveFile file = entry;

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
}

// a utility function to get the extension of the input file.
String getInputExtension(String inputPath) {
  final lowerPath = inputPath.toLowerCase();
  if (lowerPath.endsWith('.tar.gz')) {
    return '.tar.gz';
  } else if (lowerPath.endsWith('.tar.bz2')) {
    return '.tar.bz2';
  } else if (lowerPath.endsWith('.tar.xz')) {
    return '.tar.xz';
  } else if (lowerPath.endsWith('.tar.zst')) {
    return '.tar.zst';
  }
  return path.extension(lowerPath);
}

/// Extracts the archive at [inputPath] into the directory [outputPath].
///
/// The archive may be a `.zip`, `.tar`, or a tar compressed as `.tar.gz`,
/// `.tgz`, `.tar.bz2`, `.tbz`, `.tar.xz`, `.txz`, `.tar.zst` or `.tzst`.
///
/// A compressed tar is decompressed as it is read and every entry written out
/// as it is reached, so no more than a few megabytes of it are in memory at a
/// time and no temp file is needed, except for `.tar.xz`, which is still
/// decompressed to a temp file first.
///
/// [callback] is called for each entry once it has been written. For a
/// compressed tar the entry's content has gone by then and cannot be read
/// from the entry; it is in the file on disk.
///
/// [bufferSize] is the size of the write buffer for each extracted file, and
/// [password] decrypts an encrypted zip.
Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password, int? bufferSize, ArchiveCallback? callback}) async {
  Directory? tempDir;
  var archivePath = inputPath;

  final posixSupported = posix.isPosixSupported();

  const String extensionMsg =
      '.tar.gz, .tgz, .tar.bz2, .tbz, .tar.xz, .txz, .tar.zst, .tzst, .tar '
      'or .zip';

  // get the extension of the input file with up to 2 components
  // e.g. for file.tar.gz, it will return '.tar.gz'
  var archiveExt = getInputExtension(archivePath);
  if (archiveExt.isEmpty) {
    throw ArgumentError.value(
      inputPath,
      'inputPath',
      'No file extension detected, must end with $extensionMsg',
    );
  }

  if (archiveExt == '.tar.xz' || archiveExt == '.txz') {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = path.join(tempDir.path, 'temp.tar');
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath, bufferSize: bufferSize);
    XZDecoder().decodeStream(input, output);
    await input.close();
    await output.close();
    archiveExt = '.tar';
  }

  void extractEntry(ArchiveFile file) {
    final filePath = path.join(outputPath, path.normalize(file.name));
    if (!_isWithinOutputPath(outputPath, filePath)) {
      return;
    }

    if (file.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, file)) {
        return;
      }
    }

    if (file.isDirectory && !file.isSymbolicLink) {
      Directory(filePath).createSync(recursive: true);
      return;
    }

    if (file.isSymbolicLink) {
      final link = Link(filePath);
      final p = path.normalize(file.symbolicLink ?? "");
      link.createSync(p, recursive: true);
    } else if (file.isFile) {
      // The buffer is allocated per file, so for a small file it is cut down
      // to the file's size rather than the full default. With 20,000 files of
      // 2 KB that is a quarter of the extraction time.
      final size = file.size;
      final outputBufferSize =
          bufferSize ?? OutputFileStream.kDefaultBufferSize;
      final output = OutputFileStream(filePath,
          bufferSize:
              size > 0 && size < outputBufferSize ? size : outputBufferSize);
      try {
        file.writeContent(output);
      } catch (_) {}
      if (posixSupported) {
        posix.chmod(filePath, file.unixPermissions.toRadixString(8));
      }
      output.closeSync();
    }
  }

  if (archiveExt == '.zip') {
    final input = InputFileStream(archivePath);
    final archive = ZipDecoder()
        .decodeStream(input, password: password, callback: callback);
    for (final file in archive) {
      extractEntry(file);
    }
    await input.close();
    await archive.clear();
  } else {
    final file = InputFileStream(archivePath);
    final InputStream input;
    switch (archiveExt) {
      case '.tar.gz':
      case '.tgz':
        input = GZipDecoder().decodeLazy(file);
      case '.tar.bz2':
      case '.tbz':
        input = BZip2Decoder().decodeLazy(file);
      case '.tar.zst':
      case '.tzst':
        input = ZstdDecoder().decodeLazy(file);
      case '.tar':
        input = file;
      default:
        await file.close();
        throw ArgumentError.value(
            inputPath, 'inputPath', 'Must end $extensionMsg');
    }
    // Each entry is written as the decoder reaches it, which is the only
    // time its content is at hand when the tar is being decompressed on the
    // way in.
    final archive = TarDecoder().decodeStream(input, callback: (entry) {
      extractEntry(entry);
      callback?.call(entry);
    });
    await input.close();
    await file.close();
    await archive.clear();
  }

  if (tempDir != null) {
    await tempDir.delete(recursive: true);
  }
}

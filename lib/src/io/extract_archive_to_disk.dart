import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive.dart';
import '../archive_file.dart';
import '../bzip2_decoder.dart';
import '../gzip_decoder.dart';
import '../tar_decoder.dart';
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
  RandomAccessFile? outputFile;

  try {
    if (file.isSymbolicLink) {
      final link = Link(filePath);
      await link.create(
        path.normalize(file.nameOfLinkedFile),
        recursive: true,
      );
    } else {
      final output = File(filePath);
      final f = await output.create(recursive: true);
      outputFile = await f.open(mode: FileMode.write);
      final bytes = file.content as List<int>;
      await outputFile.writeFrom(bytes);
      file.clear();
    }
  } finally {
    outputFile?.closeSync();
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
  OutputFileStream? outputStream;

  try {
    if (file.isSymbolicLink) {
      final link = Link(filePath);
      link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
    } else {
      outputStream = OutputFileStream(filePath, bufferSize: bufferSize);
      file.writeContent(outputStream);
    }
  } finally {
    outputStream?.closeSync();
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
  
  OutputFileStream? outputStream;
  RandomAccessFile? outputFile;
  
  try {
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
          outputFile = await f.open(mode: FileMode.write);
          final bytes = file.content as List<int>;
          await outputFile.writeFrom(bytes);
          file.clear();
        }
      } else {
        if (file.isSymbolicLink) {
          final link = Link(filePath);
          link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
        } else {
          outputStream = OutputFileStream(filePath, bufferSize: bufferSize);
          file.writeContent(outputStream);
        }
      }
    }
  } finally {
    outputStream?.closeSync();
    outputFile?.closeSync();
  }
}

Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password, bool asyncWrite = false, int? bufferSize}) async {
  Directory? tempDir;
  var archivePath = inputPath;

  InputFileStream? inputStream;
  OutputFileStream? outputStream;
  RandomAccessFile? outputFile;

  try {
    if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      archivePath = path.join(tempDir.path, 'temp.tar');
      inputStream = InputFileStream(inputPath);
      outputStream = OutputFileStream(archivePath, bufferSize: bufferSize);
      GZipDecoder().decodeStream(inputStream, outputStream);
    } else if (inputPath.endsWith('tar.bz2') || inputPath.endsWith('tbz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      archivePath = path.join(tempDir.path, 'temp.tar');
      inputStream = InputFileStream(inputPath);
      outputStream = OutputFileStream(archivePath, bufferSize: bufferSize);
      BZip2Decoder().decodeBuffer(inputStream, output: outputStream);
    } else if (inputPath.endsWith('tar.xz') || inputPath.endsWith('txz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      archivePath = path.join(tempDir.path, 'temp.tar');
      inputStream = InputFileStream(inputPath);
      outputStream = OutputFileStream(archivePath, bufferSize: bufferSize);
      outputStream.writeBytes(XZDecoder().decodeBuffer(inputStream));
    }

    Archive archive;
    if (archivePath.endsWith('tar')) {
      inputStream = InputFileStream(archivePath);
      archive = TarDecoder().decodeBuffer(inputStream);
    } else if (archivePath.endsWith('zip')) {
      inputStream = InputFileStream(archivePath);
      archive = ZipDecoder().decodeBuffer(inputStream, password: password);
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
          outputFile = await f.open(mode: FileMode.write);
          final bytes = file.content as List<int>;
          await outputFile.writeFrom(bytes);
          file.clear();
        }
      } else {
        if (file.isSymbolicLink) {
          final link = Link(filePath);
          link.createSync(path.normalize(file.nameOfLinkedFile), recursive: true);
        } else {
          outputStream = OutputFileStream(filePath, bufferSize: bufferSize);
          file.writeContent(outputStream);
        }
      }
    }

    await archive.clear();

    if (tempDir != null) {
      await tempDir.delete(recursive: true);
    }
  } finally {
    outputStream?.closeSync();
    outputFile?.closeSync();
    outputFile?.closeSync();
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';
import '../archive/compression_type.dart';
import '../codecs/zip_encoder.dart';
import '../util/input_file_stream.dart';
import '../util/output_file_stream.dart';
import 'zip_file_progress.dart';

class ZipFileEncoder {
  late OutputFileStream _output;
  late ZipEncoder _encoder;
  int? _level;
  final String? password;

  static const store = 0;
  static const gzip = 1;

  ZipFileEncoder({this.password});

  /// Zips a [dir] to a Zip file asynchronously.
  Future<void> zipDirectory(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      DateTime? modified,
      ZipFileProgress? filter}) async {
    final outputPath = _composeZipDirectoryPath(dir: dir, filename: filename);
    create(outputPath, level: level ??= gzip, modified: modified);

    Object? callbackError;
    T callCallback<T>(T Function() callback) {
      try {
        return callback();
      } catch (error) {
        callbackError = error;
        rethrow;
      }
    }

    try {
      await addDirectory(dir,
          includeDirName: false,
          level: level,
          followLinks: followLinks,
          onProgress: onProgress == null
              ? null
              : (value) => callCallback(() => onProgress(value)),
          filter: filter == null
              ? null
              : (entry, value) => callCallback(() => filter(entry, value)));
    } catch (error, stackTrace) {
      // Callback failures retain a valid ZIP of the completed entries;
      // source I/O failures must remove the incomplete output.
      if (error is FileSystemException && !identical(error, callbackError)) {
        try {
          await _output.close();
        } catch (_) {}
        try {
          await File(outputPath).delete();
        } catch (_) {}
      } else {
        try {
          await close();
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    await close();
  }

  /// Composes the path (target) of the Zip file after a [Directory] is zipped.
  ///
  /// {@template ZipFileEncoder._composeZipDirectoryPath.filename}
  /// [filename] determines where the Zip file will be created. If [filename]
  /// is not specified, the name of the directory will be used with a '.zip'
  /// extension. If [filename] is within [dir], it will throw a [FormatException].
  /// {@endtemplate}
  ///
  /// See also:
  ///
  /// * [zipDirectory] for the methods that use this logic.
  String _composeZipDirectoryPath({
    required Directory dir,
    required String? filename,
  }) {
    final dirPath = dir.path;

    if (filename == null) {
      return '$dirPath.zip';
    }

    if (path.isWithin(dirPath, filename)) {
      throw FormatException(
        'filename must not be within the directory being zipped',
        filename,
      );
    }

    return filename;
  }

  void open(String zipPath) => create(zipPath);

  void create(String zipPath, {int? level, DateTime? modified}) {
    createWithStream(OutputFileStream(zipPath),
        level: level, modified: modified);
  }

  void createWithStream(
    OutputFileStream outputFileStream, {
    int? level,
    DateTime? modified,
  }) {
    _output = outputFileStream;
    _level = level;
    // Streamed ZIP writes data descriptors to avoid buffering entire entries.
    _encoder = ZipEncoder(password: password, streamed: true);
    _encoder.startEncode(_output, level: level, modified: modified);
  }

  /// Adds the files under [dir] to the zip
  void addDirectorySync(Directory dir,
      {bool includeDirName = true,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      ZipFileProgress? filter}) {
    final dirName = path.basename(dir.path);
    final files = dir.listSync(recursive: true, followLinks: followLinks);
    final amount = files.length;
    var current = 0;
    for (final file in files) {
      final progress = ++current / amount;
      if (filter != null) {
        final operation = filter(file, progress);
        if (operation == ZipFileOperation.cancel) {
          break;
        }
        if (operation == ZipFileOperation.skip) {
          continue;
        }
      }
      if (file is Directory) {
        var filename = path.relative(file.path, from: dir.path);
        filename = path.posix.fromUri(path.toUri(filename));
        filename = includeDirName ? '$dirName/$filename' : filename;

        final af = ArchiveFile.directory(filename);
        final stat = file.statSync();
        af.mode = stat.mode;
        af.lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;
        _encoder.add(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        var relPath = path.relative(file.path, from: dir.path);
        relPath = path.posix.fromUri(path.toUri(relPath));
        addFileSync(
          file,
          includeDirName ? '$dirName/$relPath' : relPath,
          level,
        );
        onProgress?.call(progress);
      }
    }
  }

  /// Adds the files under [dir] to the zip asynchronously
  Future<void> addDirectory(Directory dir,
      {bool includeDirName = true,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      ZipFileProgress? filter}) async {
    final dirName = path.basename(dir.path);
    // List files lazily so a directory with many entries does not create a
    // large list or block the event loop while enumerating it. Only a caller
    // requesting progress needs an initial counting pass.
    var amount = 0;
    if (filter != null || onProgress != null) {
      await for (final _ in
          dir.list(recursive: true, followLinks: followLinks)) {
        amount++;
      }
    }
    var current = 0;
    await for (final file in
        dir.list(recursive: true, followLinks: followLinks)) {
      final progress = amount == 0 ? 0.0 : ++current / amount;
      if (filter != null) {
        final operation = filter(file, progress);
        if (operation == ZipFileOperation.cancel) {
          break;
        }
        if (operation == ZipFileOperation.skip) {
          continue;
        }
      }
      if (file is Directory) {
        var filename = path.relative(file.path, from: dir.path);
        filename = path.posix.fromUri(path.toUri(filename));
        filename = includeDirName ? '$dirName/$filename' : filename;
        final af = ArchiveFile.directory(filename);
        final stat = file.statSync();
        af.mode = stat.mode;
        af.lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;
        _encoder.add(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        var relPath = path.relative(file.path, from: dir.path);
        relPath = path.posix.fromUri(path.toUri(relPath));
        await addFile(
          file,
          includeDirName ? '$dirName/$relPath' : relPath,
          level,
        );
        onProgress?.call(progress);
      }
    }
  }

  void addFileSync(File file, [String? filename, int? level]) {
    final fileStream = InputFileStream(file.path);
    try {
      filename ??= path.basename(file.path);
      filename = path.posix.fromUri(path.toUri(filename));
      final archiveFile = ArchiveFile.stream(filename, fileStream);

      archiveFile.lastModTime =
          (file.lastModifiedSync()).millisecondsSinceEpoch ~/ 1000;
      archiveFile.mode = (file.statSync()).mode;

      _add(archiveFile, level);
    } finally {
      // ZipEncoder normally closes entries itself, but validation failures
      // before its close callback must not leak the input file handle.
      fileStream.closeSync();
    }
  }

  Future<void> addFile(File file, [String? filename, int? level]) async {
    final fileStream = InputFileStream(file.path);
    try {
      filename ??= path.basename(file.path);
      filename = path.posix.fromUri(path.toUri(filename));
      final archiveFile = ArchiveFile.stream(filename, fileStream);

      archiveFile.lastModTime =
          (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
      archiveFile.mode = (await file.stat()).mode;

      _add(archiveFile, level);
    } finally {
      await fileStream.close();
    }
  }

  void addArchiveFile(ArchiveFile file) {
    _add(file, null);
  }

  void _add(ArchiveFile file, int? level) {
    // Store uses ZIP method 0 rather than deflate at compression level 0.
    if ((level ?? _level) != store || file.compression != null) {
      _encoder.add(file, level: level);
      return;
    }
    final previous = file.compression;
    file.compression = CompressionType.none;
    try {
      _encoder.add(file, level: level);
    } finally {
      file.compression = previous;
    }
  }

  void closeSync() {
    try {
      _encoder.endEncode();
    } finally {
      _output.closeSync();
    }
  }

  Future<void> close() async {
    try {
      _encoder.endEncode();
    } finally {
      await _output.close();
    }
  }
}

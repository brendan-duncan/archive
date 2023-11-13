import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive_file.dart';
import '../zip_encoder.dart';
import 'input_file_stream.dart';
import 'output_file_stream.dart';

class ZipFileEncoder {
  late String zipPath;
  late OutputFileStream _output;
  late ZipEncoder _encoder;
  final String? password;

  static const int STORE = 0;
  static const int GZIP = 1;

  ZipFileEncoder({this.password});

  /// Zips a [dir] to a Zip file synchronously.
  ///
  /// {@macro ZipFileEncoder._composeZipDirectoryPath.filename}
  ///
  /// See also:
  ///
  /// * [zipDirectoryAsync] for the asynchronous version of this method.
  /// * [_composeZipDirectoryPath] for the logic of composing the Zip file path.
  //@Deprecated('Use zipDirectoryAsync instead')
  void zipDirectory(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      DateTime? modified}) {
    create(
      _composeZipDirectoryPath(dir: dir, filename: filename),
      level: level ??= GZIP,
      modified: modified,
    );

    _addDirectory(
      dir,
      includeDirName: false,
      level: level,
      followLinks: followLinks,
      onProgress: onProgress,
    );
    close();
  }

  /// Zips a [dir] to a Zip file asynchronously.
  ///
  /// {@macro ZipFileEncoder._composeZipDirectoryPath.filename}
  ///
  /// See also:
  ///
  /// * [zipDirectory] for the synchronous version of this method.
  /// * [_composeZipDirectoryPath] for the logic of composing the Zip file path.
  Future<void> zipDirectoryAsync(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      DateTime? modified}) async {
    create(
      _composeZipDirectoryPath(dir: dir, filename: filename),
      level: level ??= GZIP,
      modified: modified,
    );

    await addDirectory(dir,
        includeDirName: false,
        level: level,
        followLinks: followLinks,
        onProgress: onProgress);
    close();
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
  /// * [zipDirectory] and [zipDirectoryAsync] for the methods that use this logic.
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
    this.zipPath = zipPath;

    _output = OutputFileStream(zipPath);
    _encoder = ZipEncoder(password: password);
    _encoder.startEncode(_output, level: level, modified: modified);
  }

  void _addDirectory(
    Directory dir, {
    bool includeDirName = true,
    int? level,
    bool followLinks = true,
    void Function(double)? onProgress,
  }) {
    final dirName = path.basename(dir.path);
    final files = dir.listSync(recursive: true, followLinks: followLinks);
    final amount = files.length;
    var current = 0;
    for (final file in files) {
      if (file is Directory) {
        var filename = path.relative(file.path, from: dir.path);
        filename = includeDirName ? '$dirName/$filename' : filename;
        final af = ArchiveFile('$filename/', 0, null);
        af.mode = file.statSync().mode;
        af.lastModTime =
            file.statSync().modified.millisecondsSinceEpoch ~/ 1000;
        af.isFile = false;
        _encoder.addFile(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        final relPath = path.relative(file.path, from: dir.path);
        _addFile(file, includeDirName ? '$dirName/$relPath' : relPath, level);
        onProgress?.call(++current / amount);
      }
    }
  }

  Future<void> addDirectory(
    Directory dir, {
    bool includeDirName = true,
    int? level,
    bool followLinks = true,
    void Function(double)? onProgress,
  }) async {
    final dirName = path.basename(dir.path);
    final files = dir.listSync(recursive: true, followLinks: followLinks);
    final futures = <Future<void>>[];
    final amount = files.length;
    var current = 0;
    for (final file in files) {
      if (file is Directory) {
        var filename = path.relative(file.path, from: dir.path);
        filename = includeDirName ? '$dirName/$filename' : filename;
        final af = ArchiveFile('$filename/', 0, null);
        af.mode = file.statSync().mode;
        af.lastModTime =
            file.statSync().modified.millisecondsSinceEpoch ~/ 1000;
        af.isFile = false;
        _encoder.addFile(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        final relPath = path.relative(file.path, from: dir.path);
        futures.add(
            addFile(file, includeDirName ? '$dirName/$relPath' : relPath, level)
                .then((value) => onProgress?.call(++current / amount)));
      }
    }
    await Future.wait(futures);
  }

  void _addFile(File file, [String? filename, int? level = GZIP]) {
    final fileStream = InputFileStream(file.path);
    final archiveFile = ArchiveFile.stream(
        filename ?? path.basename(file.path), file.lengthSync(), fileStream);

    if (level == STORE) {
      archiveFile.compress = false;
    }

    archiveFile.lastModTime =
        file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    archiveFile.mode = file.statSync().mode;

    _encoder.addFile(archiveFile);
    fileStream.closeSync();
  }

  Future<void> addFile(File file, [String? filename, int? level = GZIP]) async {
    final fileStream = InputFileStream(file.path);
    final archiveFile = ArchiveFile.stream(
        filename ?? path.basename(file.path), file.lengthSync(), fileStream);

    if (level == STORE) {
      archiveFile.compress = false;
    }

    archiveFile.lastModTime =
        file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    archiveFile.mode = file.statSync().mode;

    _encoder.addFile(archiveFile);
    await fileStream.close();
  }

  void addArchiveFile(ArchiveFile file) {
    _encoder.addFile(file);
  }

  void close() {
    _encoder.endEncode();
    _output.close();
  }
}

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

  //@Deprecated('Use zipDirectoryAsync instead')
  void zipDirectory(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      DateTime? modified}) {
    final dirPath = dir.path;
    final zipPath = filename ?? '$dirPath.zip';
    level ??= GZIP;
    create(zipPath, level: level, modified: modified);
    _addDirectory(
      dir,
      includeDirName: false,
      level: level,
      followLinks: followLinks,
      onProgress: onProgress,
    );
    close();
  }

  Future<void> zipDirectoryAsync(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      void Function(double)? onProgress,
      DateTime? modified}) async {
    final dirPath = dir.path;
    final zipPath = filename ?? '$dirPath.zip';
    level ??= GZIP;
    create(zipPath, level: level, modified: modified);
    await addDirectory(dir,
        includeDirName: false,
        level: level,
        followLinks: followLinks,
        onProgress: onProgress);
    close();
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

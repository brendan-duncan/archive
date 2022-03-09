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

  static const int STORE = 0;
  static const int GZIP = 1;

  void zipDirectory(Directory dir,
      {String? filename,
      int? level,
      bool followLinks = true,
      DateTime? modified}) {
    final dirPath = dir.path;
    final zipPath = filename ?? '$dirPath.zip';
    level ??= GZIP;
    create(zipPath, level: level, modified: modified);
    addDirectory(dir,
        includeDirName: false, level: level, followLinks: followLinks);
    close();
  }

  void open(String zipPath) => create(zipPath);

  void create(String zipPath, {int? level, DateTime? modified}) {
    this.zipPath = zipPath;

    _output = OutputFileStream(zipPath);
    _encoder = ZipEncoder();
    _encoder.startEncode(_output, level: level, modified: modified);
  }

  void addDirectory(Directory dir,
      {bool includeDirName = true, int? level, bool followLinks = true}) {
    List files = dir.listSync(recursive: true, followLinks: followLinks);
    for (var file in files) {
      if (file is! File) {
        continue;
      }

      final f = file;
      final dirName = path.basename(dir.path);
      final relPath = path.relative(f.path, from: dir.path);
      addFile(
          f, includeDirName ? (dirName + '/' + relPath) : relPath, level);
    }
  }

  void addFile(File file, [String? filename, int? level = GZIP]) {
    var fileStream = InputFileStream(file.path);
    var archiveFile = ArchiveFile.stream(
        filename ?? path.basename(file.path), file.lengthSync(), fileStream);

    if (level == STORE) {
      archiveFile.compress = false;
    }

    archiveFile.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    archiveFile.mode = file.statSync().mode;

    _encoder.addFile(archiveFile);
    fileStream.close();
  }

  void addArchiveFile(ArchiveFile file) {
    _encoder.addFile(file);
  }

  void close() {
    _encoder.endEncode();
    _output.close();
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive_file.dart';
import '../gzip_encoder.dart';
import '../tar_encoder.dart';
import 'input_file_stream.dart';
import 'output_file_stream.dart';

class TarFileEncoder {
  late String tarPath;
  late OutputFileStream _output;
  late TarEncoder _encoder;

  static const int STORE = 0;
  static const int GZIP = 1;

  void tarDirectory(
    Directory dir, {
    int compression = STORE,
    String? filename,
    bool followLinks = true,
    int? level,
  }) {
    final dirPath = dir.path;
    var tarPath = filename ?? '$dirPath.tar';
    final tgzPath = filename ?? '$dirPath.tar.gz';

    Directory tempDir;
    if (compression == GZIP) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      tarPath = tempDir.path + '/temp.tar';
    }

    // Encode a directory from disk to disk, no memory
    open(tarPath);
    addDirectory(Directory(dirPath), followLinks: followLinks);
    close();

    if (compression == GZIP) {
      final input = InputFileStream(tarPath);
      final output = OutputFileStream(tgzPath);
      GZipEncoder().encode(input, output: output, level: level);
      input.close();
      File(input.path).deleteSync();
    }
  }

  void open(String tarPath) => create(tarPath);

  void create(String tarPath) {
    this.tarPath = tarPath;
    _output = OutputFileStream(tarPath);
    _encoder = TarEncoder();
    _encoder.start(_output);
  }

  void addDirectory(Directory dir, {bool followLinks = true}) {
    List files = dir.listSync(recursive: true, followLinks: followLinks);

    for (var fe in files) {
      if (fe is! File) {
        continue;
      }

      final f = fe;
      final relPath = path.relative(f.path, from: dir.path);
      addFile(f, relPath);
    }
  }

  void addFile(File file, [String? filename]) {
    final fileStream = InputFileStream(file.path);
    final f = ArchiveFile.stream(
        filename ?? file.path, file.lengthSync(), fileStream);
    f.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    f.mode = file.statSync().mode;
    _encoder.add(f);
    fileStream.close();
  }

  void close() {
    _encoder.finish();
    _output.close();
  }
}

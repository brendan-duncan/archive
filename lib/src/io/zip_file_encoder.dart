import 'dart:io';
import 'package:path/path.dart' as path;
import 'input_file_stream.dart';
import 'output_file_stream.dart';
import '../archive_file.dart';
import '../zip_encoder.dart';

class ZipFileEncoder {
  String zip_path;
  OutputFileStream _output;
  ZipEncoder _encoder;

  static const int STORE = 0;
  static const int GZIP = 1;

  void zipDirectory(Directory dir, {String filename}) {
    String dirPath = dir.path;
    String zip_path = filename != null ? filename : '${dirPath}.zip';
    open(zip_path);
    addDirectory(dir);
    close();
  }

  void open(String zip_path) {
    this.zip_path = zip_path;

    _output = new OutputFileStream(zip_path);
    _encoder = new ZipEncoder();
    _encoder.startEncode(_output);
  }

  void addDirectory(Directory dir) {
    List files = dir.listSync(recursive: true);
    for (var file in files) {
      if (file is! File) {
        continue;
      }

      File f = file as File;
      String rel_path = path.relative(f.path, from: dir.path);
      addFile(f, rel_path);
    }
  }

  void addFile(File file, [String filename]) {
    var file_stream = new InputFileStream.file(file);
    var f = new ArchiveFile.stream(filename == null ? file.path : filename,
        file.lengthSync(), file_stream);

    f.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch;
    f.mode = file.statSync().mode;

    _encoder.addFile(f);
    file_stream.close();
  }

  void close() {
    _encoder.endEncode();
    _output.close();
  }
}

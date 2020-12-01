import 'dart:io';
import 'package:path/path.dart' as path;
import 'input_file_stream.dart';
import 'output_file_stream.dart';
import '../archive_file.dart';
import '../zip_encoder.dart';

class ZipFileEncoder {
  late String zip_path;
  late OutputFileStream _output;
  late ZipEncoder _encoder;

  static const int STORE = 0;
  static const int GZIP = 1;

  void zipDirectory(Directory dir, {String? filename, int? level}) {
    final dirPath = dir.path;
    final zip_path = filename ?? '${dirPath}.zip';
    level ??= GZIP;
    create(zip_path, level: level);
    addDirectory(dir, includeDirName: false, level: level);
    close();
  }

  void open(String zip_path) => create(zip_path);

  void create(String zip_path, {int? level}) {
    this.zip_path = zip_path;

    _output = OutputFileStream(zip_path);
    _encoder = ZipEncoder();
    _encoder.startEncode(_output, level: level);
  }

  void addDirectory(Directory dir, {bool includeDirName = true, int? level}) {
    List files = dir.listSync(recursive: true);
    for (var file in files) {
      if (file is! File) {
        continue;
      }

      final f = file;
      final dir_name = path.basename(dir.path);
      final rel_path = path.relative(f.path, from: dir.path);
      addFile(
          f, includeDirName ? (dir_name + '/' + rel_path) : rel_path, level);
    }
  }

  void addFile(File file, [String? filename, int? level = GZIP]) {
    var file_stream = InputFileStream.file(file);
    var archiveFile = ArchiveFile.stream(
        filename ?? path.basename(file.path), file.lengthSync(), file_stream);

    if (level == STORE) {
      archiveFile.compress = false;
    }

    archiveFile.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch;
    archiveFile.mode = file.statSync().mode;

    _encoder.addFile(archiveFile);
    file_stream.close();
  }
  
  void addArchiveFile(ArchiveFile file){
    _encoder.addFile(file);
  }

  void close() {
    _encoder.endEncode();
    _output.close();
  }
}

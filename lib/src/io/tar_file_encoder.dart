import 'dart:io';
import 'package:path/path.dart' as path;
import 'input_file_stream.dart';
import 'output_file_stream.dart';
import '../archive_file.dart';
import '../gzip_encoder.dart';
import '../tar_encoder.dart';

class TarFileEncoder {
  late String tar_path;
  late OutputFileStream _output;
  late TarEncoder _encoder;

  static const int STORE = 0;
  static const int GZIP = 1;

  void tarDirectory(Directory dir,
      {int compression = STORE, String? filename}) {
    final dirPath = dir.path;
    var tar_path = filename ?? '${dirPath}.tar';
    final tgz_path = filename ?? '${dirPath}.tar.gz';

    Directory temp_dir;
    if (compression == GZIP) {
      temp_dir = Directory.systemTemp.createTempSync('dart_archive');
      tar_path = temp_dir.path + '/temp.tar';
    }

    // Encode a directory from disk to disk, no memory
    open(tar_path);
    addDirectory(Directory(dirPath));
    close();

    if (compression == GZIP) {
      final input = InputFileStream(tar_path);
      final output = OutputFileStream(tgz_path);
      GZipEncoder().encode(input, output: output);
      input.close();
      File(input.path).deleteSync();
    }
  }

  void open(String tar_path) => create(tar_path);

  void create(String tar_path) {
    this.tar_path = tar_path;
    _output = OutputFileStream(tar_path);
    _encoder = TarEncoder();
    _encoder.start(_output);
  }

  void addDirectory(Directory dir) {
    List files = dir.listSync(recursive: true);

    for (var fe in files) {
      if (fe is! File) {
        continue;
      }

      final f = fe;
      final rel_path = path.relative(f.path, from: dir.path);
      addFile(f, rel_path);
    }
  }

  void addFile(File file, [String? filename]) {
    final file_stream = InputFileStream.file(file);
    final f = ArchiveFile.stream(
        filename ?? file.path, file.lengthSync(), file_stream);
    f.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch;
    f.mode = file.statSync().mode;
    _encoder.add(f);
    file_stream.close();
  }

  void close() {
    _encoder.finish();
    _output.close();
  }
}

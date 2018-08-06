import 'dart:io';
import 'package:path/path.dart' as path;
import 'input_file_stream.dart';
import 'output_file_stream.dart';
import '../archive_file.dart';
import '../gzip_encoder.dart';
import '../tar_encoder.dart';

class TarFileEncoder {
  String tar_path;
  OutputFileStream _output;
  TarEncoder _encoder;

  static const int STORE = 0;
  static const int GZIP = 1;

  void tarDirectory(Directory dir, {int compression: STORE,
                    String filename}) {
    String dirPath = dir.path;
    String tar_path = filename != null ? filename : '${dirPath}.tar';
    String tgz_path = filename != null ? filename : '${dirPath}.tar.gz';

    Directory temp_dir;
    if (compression == GZIP) {
      temp_dir = Directory.systemTemp.createTempSync('dart_archive');
      tar_path = temp_dir.path + '/temp.tar';
    }

    // Encode a directory from disk to disk, no memory
    open(tar_path);
    addDirectory(new Directory(dirPath));
    close();

    if (compression == GZIP) {
      InputFileStream input = new InputFileStream(tar_path);
      OutputFileStream output = new OutputFileStream(tgz_path);
      new GZipEncoder().encode(input, output: output);
      input.close();
      new File(input.path).deleteSync();
    }
  }

  void open(String tar_path) => create(tar_path);

  void create(String tar_path) {
    this.tar_path = tar_path;
    _output = new OutputFileStream(tar_path);
    _encoder = new TarEncoder();
    _encoder.start(_output);
  }

  void addDirectory(Directory dir) {
    List files = dir.listSync(recursive:true);

    for (var fe in files) {
      if (fe is! File) {
        continue;
      }

      File f = fe as File;
      String rel_path = path.relative(f.path, from: dir.path);
      addFile(f, rel_path);
    }
  }

  void addFile(File file, [String filename]) {
    InputFileStream file_stream = new InputFileStream.file(file);
    ArchiveFile f = new ArchiveFile.stream(filename == null ? file.path : filename,
        file.lengthSync(), file_stream);
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

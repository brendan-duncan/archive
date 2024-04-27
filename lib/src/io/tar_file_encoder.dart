import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_directory.dart';
import '../archive/archive_file.dart';
import '../codecs/gzip_encoder.dart';
import '../codecs/tar_encoder.dart';
import '../util/input_file_stream.dart';
import '../util/output_file_stream.dart';

class TarFileEncoder {
  late String tarPath;
  late OutputFileStream _output;
  late TarEncoder _encoder;

  static const int store = 0;
  static const int gzip = 1;

  Future<void> tarDirectory(
    Directory dir, {
    int compression = store,
    String? filename,
    bool followLinks = true,
    int? level,
  }) async {
    final dirPath = dir.path;
    var tarPath = filename ?? '$dirPath.tar';
    final tgzPath = filename ?? '$dirPath.tar.gz';

    Directory tempDir;
    if (compression == gzip) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      tarPath = '${tempDir.path}/temp.tar';
    }

    // Encode a directory from disk to disk, no memory
    open(tarPath);
    await addDirectory(Directory(dirPath), followLinks: followLinks);
    await close();

    if (compression == gzip) {
      final input = InputFileStream(tarPath);
      final output = OutputFileStream(tgzPath);
      GZipEncoder().encodeStream(input, output, level: level ?? 6);
      await input.close();
      await File(tarPath).delete();
    }
  }

  void open(String tarPath) => create(tarPath);

  void create(String tarPath) {
    this.tarPath = tarPath;
    _output = OutputFileStream(tarPath);
    _encoder = TarEncoder();
    _encoder.start(_output);
  }

  Future<void> addDirectory(Directory dir,
      {bool followLinks = true, bool includeDirName = true}) async {
    final files = dir.listSync(recursive: true, followLinks: followLinks);

    final dirName = path.basename(dir.path);
    var futures = <Future<void>>[];
    for (var file in files) {
      if (file is Directory) {
        var filename = path.relative(file.path, from: dir.path);
        filename = includeDirName ? '$dirName/$filename' : filename;
        final af = ArchiveDirectory('$filename/');
        af.mode = file.statSync().mode;
        _encoder.add(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        final relPath = path.relative(file.path, from: dir.path);
        futures
            .add(addFile(file, includeDirName ? '$dirName/$relPath' : relPath));
      }
    }

    await Future.wait(futures);
  }

  Future<void> addFile(File file, [String? filename]) async {
    final fileStream = InputFileStream(file.path);
    final f =
        ArchiveFile.stream(filename ?? path.basename(file.path), fileStream);
    f.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    f.mode = file.statSync().mode;
    _encoder.add(f);
    await fileStream.close();
  }

  Future<void> close() async {
    _encoder.finish();
    await _output.close();
  }
}

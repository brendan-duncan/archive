import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';
import '../codecs/gzip_encoder.dart';
import '../codecs/tar_encoder.dart';
import '../util/input_file_stream.dart';
import '../util/output_file_stream.dart';
import 'zip_file_progress.dart';

class TarFileEncoder {
  late String tarPath;
  late OutputFileStream _output;
  late TarEncoder _encoder;

  static const store = 0;
  static const gzip = 1;

  Future<void> tarDirectory(Directory dir,
      {int compression = store,
      String? filename,
      bool followLinks = true,
      int? level,
      ZipFileProgress? filter}) async {
    final dirPath = dir.path;
    var tarPath = filename ?? '$dirPath.tar';
    final tgzPath = filename ?? '$dirPath.tar.gz';

    Directory tempDir;
    if (compression == gzip) {
      tempDir = await Directory.systemTemp.createTemp('dart_archive');
      tarPath = '${tempDir.path}/temp.tar';
    }

    // Encode a directory from disk to disk, no memory
    open(tarPath);
    await addDirectory(Directory(dirPath),
        followLinks: followLinks, filter: filter);
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
      {bool followLinks = true,
      bool includeDirName = true,
      ZipFileProgress? filter}) async {
    final files = dir.listSync(recursive: true, followLinks: followLinks);

    final dirName = path.basename(dir.path);
    final numFiles = files.length;
    var fileCount = 0;
    for (final file in files) {
      final progress = ++fileCount / numFiles;
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
        filename = includeDirName ? '$dirName/$filename' : filename;
        final af = ArchiveFile.directory('$filename/');
        af.mode = (await file.stat()).mode;
        _encoder.add(af);
      } else if (file is File) {
        final dirName = path.basename(dir.path);
        final relPath = path.relative(file.path, from: dir.path);
        await addFile(file, includeDirName ? '$dirName/$relPath' : relPath);
      }
    }
  }

  Future<void> addFile(File file, [String? filename]) async {
    final fileStream = InputFileStream(file.path);
    final f =
        ArchiveFile.stream(filename ?? path.basename(file.path), fileStream);
    f.lastModTime = (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    f.mode = (await file.stat()).mode;
    _encoder.add(f);
    await fileStream.close();
  }

  Future<void> close() async {
    _encoder.finish();
    await _output.close();
  }
}

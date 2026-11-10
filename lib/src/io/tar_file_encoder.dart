import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';
import '../codecs/tar_encoder.dart';
import '../codecs/zlib/_zlib_encoder_base.dart';
import '../codecs/zstd/zstd_chunked.dart';
import '../codecs/zstd/zstd_level_params.dart';
import '../util/chunked_sink.dart';
import '../util/input_file_stream.dart';
import '../util/output_file_stream.dart';
import 'zip_file_progress.dart';

class TarFileEncoder {
  late String tarPath;
  late OutputFileStream _output;
  late TarEncoder _encoder;

  static const store = 0;
  static const gzip = 1;
  static const zstd = 2;

  Future<void> tarDirectory(Directory dir,
      {int compression = store,
      String? filename,
      bool followLinks = true,
      int? level,
      ZipFileProgress? filter}) async {
    final dirPath = dir.path;
    if (compression == gzip || compression == zstd) {
      await _tarDirectoryCompressed(
        dir,
        filename ??
            (compression == gzip ? '$dirPath.tar.gz' : '$dirPath.tar.zst'),
        compression: compression,
        level: level,
        followLinks: followLinks,
        filter: filter,
      );
      return;
    }

    // An uncompressed TAR still writes directly to the target file.
    open(filename ?? '$dirPath.tar');
    try {
      await addDirectory(dir, followLinks: followLinks, filter: filter);
    } finally {
      await close();
    }
  }

  /// Compress each TAR chunk as it is created. Neither gzip nor zstd needs
  /// an entire temporary TAR on disk or in memory.
  Future<void> _tarDirectoryCompressed(
    Directory dir,
    String outputPath, {
    required int compression,
    int? level,
    required bool followLinks,
    ZipFileProgress? filter,
  }) async {
    tarPath = outputPath;
    final output = OutputFileStream(outputPath);
    _output = output;
    SinkOutputStream? tarSink;
    try {
      if (compression == gzip) {
        final gzipEncoder = GZipCodec(level: level ?? 6)
            .encoder
            .startChunkedConversion(ZLibOutputSink(output));
        tarSink = SinkOutputStream(gzipEncoder);
      } else {
        final zstdEncoder = ZstdChunkedEncoder(
          ZLibOutputSink(output),
          level: level ?? zstdDefaultLevel,
          checksum: true,
        );
        tarSink = SinkOutputStream(zstdEncoder);
      }
      _encoder = TarEncoder()..start(tarSink);

      await addDirectory(
        dir,
        followLinks: followLinks,
        filter: filter,
      );
      _encoder.finish();
      // Finalizes the compressed frame, checksums and any trailing bytes.
      tarSink.closeSync();
      await output.close();
    } catch (_) {
      // A failed entry or encoder initialization must never leave a partial
      // archive at the destination.
      try {
        tarSink?.closeSync();
      } catch (_) {}
      try {
        await output.close();
      } catch (_) {}
      try {
        await File(outputPath).delete();
      } catch (_) {}
      rethrow;
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
    Stream<FileSystemEntity> files() async* {
      await for (final file
          in dir.list(recursive: true, followLinks: followLinks)) {
        if (file is File &&
            await FileSystemEntity.identical(file.path, tarPath)) {
          continue;
        }
        yield file;
      }
    }

    // Only filters need a preliminary count for progress fractions.
    var numFiles = 0;
    if (filter != null) {
      await for (final _ in files()) {
        numFiles++;
      }
    }

    final dirName = path.basename(dir.path);
    var fileCount = 0;
    await for (final file in files()) {
      final progress = numFiles == 0 ? 0.0 : ++fileCount / numFiles;
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
    try {
      final f =
          ArchiveFile.stream(filename ?? path.basename(file.path), fileStream);
      f.lastModTime =
          (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
      f.mode = (await file.stat()).mode;
      _encoder.add(f);
    } finally {
      // A stat or encoding error must not retain an open file descriptor.
      await fileStream.close();
    }
  }

  Future<void> close() async {
    try {
      _encoder.finish();
    } finally {
      await _output.close();
    }
  }
}

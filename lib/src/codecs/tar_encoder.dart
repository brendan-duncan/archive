import 'dart:convert';
import 'dart:typed_data';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/_cast.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'tar/tar_file.dart';

/// Encode an [Archive] object into a tar formatted buffer.
class TarEncoder {
  final Encoding filenameEncoding;

  TarEncoder({this.filenameEncoding = const Utf8Codec()});

  void encodeStream(Archive archive, OutputStream output) {
    start(output);
    for (final file in archive) {
      add(file);
    }
    finish();
  }

  Uint8List encodeBytes(Archive archive, {OutputStream? output}) {
    output ??= OutputMemoryStream();
    encodeStream(archive, output);
    return output.getBytes();
  }

  /// Alias for [encodeBytes], kept for backwards compatibility.
  List<int> encode(Archive archive, {OutputStream? output}) =>
      encodeBytes(archive, output: output);

  void start([OutputStream? outputStream]) {
    _outputStream = outputStream ?? OutputMemoryStream();
  }

  void add(ArchiveFile entry) {
    if (_outputStream == null) {
      return;
    }

    // GNU tar files store extra long file names in a separate file
    if (entry.name.length > 100) {
      final ts = TarFile();
      ts.filename = '././@LongLink';
      ts.fileSize = entry.name.length;
      ts.mode = 0;
      ts.ownerId = 0;
      ts.groupId = 0;
      ts.lastModTime = 0;
      ts.contentBytes = castToUint8List(utf8.encode(entry.name));
      ts.write(_outputStream!);
    }

    final ts = TarFile();
    ts.filename = entry.name;
    ts.mode = entry.mode;
    ts.ownerId = entry.ownerId;
    ts.groupId = entry.groupId;
    ts.lastModTime = entry.lastModTime;
    if (!entry.isFile) {
      ts.typeFlag = TarFile.directory;
    } else {
      final file = entry;
      if (file.symbolicLink != null) {
        ts.typeFlag = TarFile.symbolicLink;
        ts.nameOfLinkedFile = file.symbolicLink;
      } else {
        ts.fileSize = file.size;
        ts.contentBytes = file.getContent()?.toUint8List();
      }
    }
    ts.write(_outputStream!);
  }

  void finish() {
    if (_outputStream == null) {
      return;
    }
    // At the end of the archive file there are two 512-byte blocks filled
    // with binary zeros as an end-of-file marker.
    final eof = Uint8List(1024);
    _outputStream!.writeBytes(eof);
    _outputStream!.flush();
    _outputStream = null;
  }

  OutputStream? _outputStream;
}

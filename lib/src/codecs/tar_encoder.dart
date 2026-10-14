import 'dart:convert';
import 'dart:typed_data';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/_cast.dart';
import '../util/_link_target.dart';
import '../util/file_content.dart';
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
    final ts = addHeader(entry);
    if (ts == null) {
      return;
    }
    final body = ts.contentStream;
    if (body != null) {
      _outputStream!.writeStream(body);
    }
    final pad = ts.padding;
    if (pad > 0) {
      _outputStream!.writeBytes(Uint8List(pad));
    }
  }

  /// Writes the pre-content metadata (GNU long names and links) followed by
  /// the entry's actual header. It returns the file so you can stream
  /// its `contentStream` and `padding` chunk-by-chunk
  TarFile? addHeader(ArchiveFile entry) {
    if (_outputStream == null) {
      return null;
    }

    // GNU tar files store extra long file names in a separate file. Long in
    // bytes as encoded, which is what the header field holds, and the size
    // of the separate file
    final paxName = entry.name.codeUnits.any((c) => c > 0x7f);
    final name = paxName ? Uint8List(0) : filenameEncoding.encode(entry.name);
    final linkName = entry.isHardLink
        ? hardLinkFromRoot(entry.name, entry.symbolicLink ?? '')
        : entry.symbolicLink;
    final paxLink =
        entry.isSymbolicLink && linkName!.codeUnits.any((c) => c > 0x7f);
    if (paxName || paxLink) {
      final records = BytesBuilder(copy: false);
      if (paxName) {
        records.add(_paxRecord('path', entry.name));
      }
      if (paxLink) {
        records.add(_paxRecord('linkpath', linkName));
      }
      final ts = TarFile();
      ts.filename = 'PaxHeader';
      ts.typeFlag = TarFile.exHeader;
      ts.fileSize = records.length;
      ts.mode = 0;
      ts.ownerId = 0;
      ts.groupId = 0;
      ts.lastModTime = 0;
      ts.contentBytes = records.takeBytes();
      ts.write(_outputStream!, filenameEncoder: filenameEncoding);
    }

    if (!paxName && name.length > 100) {
      final ts = TarFile();
      ts.filename = '././@LongLink';
      // What other tars key on: the name alone is only read back by this one
      ts.typeFlag = TarFile.longName;
      ts.fileSize = name.length;
      ts.mode = 0;
      ts.ownerId = 0;
      ts.groupId = 0;
      ts.lastModTime = 0;
      ts.contentBytes = castToUint8List(name);
      ts.write(_outputStream!, filenameEncoder: filenameEncoding);
    }

    // After the name, which is the order GNU writes the two in
    if (entry.isSymbolicLink && !paxLink) {
      final link = filenameEncoding.encode(linkName!);
      if (link.length > 100) {
        final ts = TarFile();
        ts.filename = '././@LongLink';
        ts.typeFlag = TarFile.longLinkName;
        ts.fileSize = link.length;
        ts.mode = 0;
        ts.ownerId = 0;
        ts.groupId = 0;
        ts.lastModTime = 0;
        ts.contentBytes = castToUint8List(link);
        ts.write(_outputStream!, filenameEncoder: filenameEncoding);
      }
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
      if (file.isSymbolicLink) {
        ts.typeFlag = file.isHardLink ? TarFile.hardLink : TarFile.symbolicLink;
        ts.nameOfLinkedFile = linkName;
      } else {
        ts.fileSize = file.size;
        // As stored: write copies a stream in chunks, where getContent would
        // read the whole entry into memory first
        final raw = file.rawContent;
        if (raw != null && !raw.isCompressed) {
          final body = raw.getStream();
          ts.fileSize = body.length;
          ts.content = FileContentStream(body);
        } else {
          final bytes = file.getContent()?.toUint8List();
          ts.contentBytes = bytes;
          ts.fileSize = bytes?.length ?? 0;
        }
      }
    }
    final encodable =
        _encodes(entry.name) && (!entry.isSymbolicLink || _encodes(linkName!));
    ts.write(_outputStream!,
        filenameEncoder: encodable ? filenameEncoding : utf8, headerOnly: true);
    return ts;
  }

  bool _encodes(String value) {
    try {
      filenameEncoding.encode(value);
      return true;
    } catch (_) {
      return false;
    }
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

  static Uint8List _paxRecord(String key, String value) {
    final body = [...utf8.encode(' $key='), ...utf8.encode(value), 0x0a];
    var length = body.length + 1;
    while ('$length'.length + body.length != length) {
      length = '$length'.length + body.length;
    }
    return Uint8List.fromList([...ascii.encode('$length'), ...body]);
  }

  OutputStream? _outputStream;
}

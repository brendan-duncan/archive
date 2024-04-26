import 'dart:convert';
import 'dart:typed_data';

import '../util/file_content.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'archive_entry.dart';
import 'compression_type.dart';

/// A file contained in an Archive.
class ArchiveFile extends ArchiveEntry {
  /// The uncompressed size of the file
  @override
  int size = 0;

  FileContent? _rawContent;
  FileContent? _content;
  CompressionType compression = CompressionType.deflate;
  @override
  bool isFile = true;

  int get unixPermissions => mode & 0x1ff;

  factory ArchiveFile.list(String name, List<int> content) => ArchiveFile.bytes(
      name, content is Uint8List ? content : Uint8List.fromList(content));

  ArchiveFile.bytes(String name, Uint8List content)
      : super(name: name, mode: 0x1a4) {
    _content = FileContentMemory(content);
    _rawContent = FileContentMemory(content);
    size = content.length;
  }

  factory ArchiveFile.typedData(String name, TypedData data) =>
      ArchiveFile.bytes(name,
          Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes));

  ArchiveFile.string(String name, String content)
      : super(name: name, mode: 0x1a4) {
    final bytes = utf8.encode(content);
    size = bytes.length;
    _content = FileContentMemory(bytes);
    _rawContent = FileContentMemory(bytes);
  }

  ArchiveFile.stream(String name, InputStream stream,
      {this.compression = CompressionType.deflate})
      : super(name: name, mode: 0x1a4) {
    size = stream.length;
    _rawContent = FileContentStream(stream);
  }

  ArchiveFile.file(String name, this.size, FileContent file,
      {this.compression = CompressionType.deflate})
      : super(name: name, mode: 0x1a4) {
    _rawContent = file;
  }

  ArchiveFile.symlink(String name, String symbolicLink)
      : super(name: name, mode: 0x1a4) {
    this.symbolicLink = symbolicLink;
  }

  ArchiveFile.noData(String name) : super(name: name, mode: 0x1a4);

  void writeContent(OutputStream output, {bool freeMemory = true}) {
    if (_content == null) {
      if (_rawContent == null) {
        return;
      }
      decompress(output);
    }

    _content?.write(output);

    if (freeMemory && _content != null) {
      _content!.closeSync();
      _content = null;
    }
  }

  /// Get the content without decompressing it first.
  FileContent? get rawContent => _rawContent;

  /// Get the content of the file, decompressing on demand as necessary.
  @override
  InputStream? getContent() {
    if (_content == null) {
      decompress();
    }
    return _content?.getStream();
  }

  /// Get the decompressed bytes of the file.
  Uint8List? readBytes() {
    final stream = getContent();
    return stream?.toUint8List();
  }

  @override
  Future<void> close() async {
    final futures = <Future<void>>[];
    if (_content != null) {
      futures.add(_content!.close());
    }
    if (_rawContent != null) {
      futures.add(_rawContent!.close());
    }
    _content = null;
    _rawContent = null;
    await Future.wait(futures);
  }

  @override
  void closeSync() {
    if (_content != null) {
      _content!.closeSync();
    }
    if (_rawContent != null) {
      _rawContent!.closeSync();
    }
    _content = null;
    _rawContent = null;
  }

  @override
  Future<void> clear() async {
    _content = null;
  }

  @override
  void clearSync() {
    _content = null;
  }

  /// If the file data is compressed, decompress it.
  void decompress([OutputStream? output]) {
    if (_content != null) {
      if (output != null) {
        output.writeStream(_content!.getStream());
      }
      return;
    }

    if (_rawContent != null) {
      if (output != null) {
        _rawContent!.decompress(output);
      } else {
        final rawStream = _rawContent!.getStream();
        final bytes = rawStream.toUint8List();
        _content = FileContentMemory(bytes);
      }
    }
  }

  /// Is the data stored by this file currently compressed?
  bool get isCompressed =>
      _content == null && _rawContent != null && _rawContent!.isCompressed;
}

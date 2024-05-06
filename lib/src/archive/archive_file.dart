import 'dart:convert';
import 'dart:typed_data';

import '../util/file_content.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'archive_entry.dart';
import 'compression_type.dart';

/// A file contained in an Archive.
class ArchiveFile extends ArchiveEntry {
  FileContent? _rawContent;
  FileContent? _content;
  @override
  int size = 0;

  /// The type of compression the file content is compressed with.
  CompressionType compression = CompressionType.deflate;

  @override
  bool isFile = true;

  /// The unix permission flags of the file.
  int get unixPermissions => mode & 0x1ff;

  /// A file storing the given [data].
  ArchiveFile.bytes(String name, List<int> data)
      : super(name: name, mode: 0x1a4) {
    _content = FileContentMemory(data);
    _rawContent = FileContentMemory(data);
    size = data.length;
  }

  /// A file storing the given [data].
  factory ArchiveFile.typedData(String name, TypedData data) =>
      ArchiveFile.bytes(name,
          Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes));

  /// A file storing the given string data [content].
  ArchiveFile.string(String name, String content)
      : super(name: name, mode: 0x1a4) {
    final bytes = utf8.encode(content);
    size = bytes.length;
    _content = FileContentMemory(bytes);
    _rawContent = FileContentMemory(bytes);
  }

  /// A file that gets its content from the given [stream].
  ArchiveFile.stream(String name, InputStream stream,
      {this.compression = CompressionType.deflate})
      : super(name: name, mode: 0x1a4) {
    size = stream.length;
    _rawContent = FileContentStream(stream);
  }

  /// A file that gets its content from the given [file].
  ArchiveFile.file(String name, this.size, FileContent file,
      {this.compression = CompressionType.deflate})
      : super(name: name, mode: 0x1a4) {
    _rawContent = file;
  }

  /// A file that's a symlink to another file.
  ArchiveFile.symlink(String name, String symbolicLink)
      : super(name: name, mode: 0x1a4) {
    this.symbolicLink = symbolicLink;
  }

  /// An empty file.
  ArchiveFile.noData(String name) : super(name: name, mode: 0x1a4);

  /// Write the contents of the file to the given [output]. If [freeMemory]
  /// is true, then any storage of decompressed data will be freed after
  /// the write has completed.
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

  /// Alias to [readBytes], kept for backwards compatibility.
  List<int> get content => readBytes() ?? [];

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
  /// Optionally write the decompressed content to [output], otherwise the
  /// decompressed content is stored with this ArchiveFile in its cached
  /// contents.
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

  /// True if the data stored by this file currently compressed
  bool get isCompressed =>
      _content == null && _rawContent != null && _rawContent!.isCompressed;
}

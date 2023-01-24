import 'dart:typed_data';

//import '../codecs/zlib/inflate.dart';
//import '../codecs/zlib/inflate_buffer.dart';
import '../util/file_content.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'archive_entry.dart';
import 'compression_type.dart';

/// A file contained in an Archive.
class ArchiveFile extends ArchiveEntry {
  /// The uncompressed size of the file
  int size = 0;

  /// If this is a symbolic link, this is the path to the file its linked to.
  String? linkPath;
  FileContent? _rawContent;
  FileContent? _content;
  CompressionType compression = CompressionType.none;
  @override
  bool isFile = true;

  int get unixPermissions => mode & 0x1ff;

  ArchiveFile.bytes(String name, Uint8List content)
      : super(name: name, mode: 0x1a4) {
    _content = FileContentMemory(content);
    _rawContent = FileContentMemory(content);
    size = content.length;
  }

  ArchiveFile.string(String name, String content)
      : super(name: name, mode: 0x1a4) {
    final bytes = Uint8List.fromList(content.codeUnits);
    size = bytes.length;
    _content = FileContentMemory(bytes);
    _rawContent = FileContentMemory(bytes);
  }

  ArchiveFile.stream(String name, this.size, InputStream stream,
      {this.compression = CompressionType.none})
      : super(name: name, mode: 0x1a4) {
    size = stream.length;
    _rawContent = FileContentStream(stream);
  }

  ArchiveFile.file(String name, this.size, FileContent file,
      {this.compression = CompressionType.none})
      : super(name: name, mode: 0x1a4) {
    _rawContent = file;
  }

  Future<void> writeContent(OutputStream output,
      {bool freeMemory = true}) async {
    if (_content == null) {
      if (_rawContent == null) {
        return;
      }
      await decompress(output);
    }

    await _content?.write(output);

    if (freeMemory && _content != null) {
      await _content!.close();
      _content = null;
    }
  }

  /// Get the content without decompressing it first.
  FileContent? get rawContent => _rawContent;

  /// Get the content of the file, decompressing on demand as necessary.
  Future<InputStream?> getContent() async {
    if (_content == null) {
      await decompress();
    }
    return _content?.getStream();
  }

  void clear() {
    _content = null;
  }

  Future<Uint8List?> readBytes() async {
    final stream = await getContent();
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

  /// If the file data is compressed, decompress it.
  Future<void> decompress([OutputStream? output]) async {
    if (_content == null && _rawContent != null) {
      if (compression != CompressionType.none) {
        if (output != null) {
          await _rawContent!.decompress(output);
        } else {
          final rawStream = await _rawContent!.getStream();
          final bytes = await rawStream.toUint8List();
          _content = FileContentMemory(bytes);
        }
      } else {
        if (output != null) {
          await output.writeStream(await _rawContent!.getStream());
        } else {
          _content = _rawContent;
        }
      }
      compression = CompressionType.none;
    }
  }

  /// Is the data stored by this file currently compressed?
  bool get isCompressed => compression != CompressionType.none;
}

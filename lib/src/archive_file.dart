import 'util/input_stream.dart';
import 'zlib/inflate.dart';

/// A file contained in an Archive.
class ArchiveFile {
  static const int STORE = 0;
  static const int DEFLATE = 8;

  String name;

  /// The uncompressed size of the file
  int size = 0;
  int mode = 420; // octal 644 (-rw-r--r--)
  int ownerId = 0;
  int groupId = 0;
  int lastModTime = 0;
  bool isFile = true;
  bool isSymbolicLink = false;
  String nameOfLinkedFile = '';

  /// The crc32 checksum of the uncompressed content.
  int? crc32;
  String? comment;

  /// If false, this file will not be compressed when encoded to an archive
  /// format such as zip.
  bool compress = true;

  int get unixPermissions {
    return mode & 0x1FF;
  }

  ArchiveFile(this.name, this.size, dynamic content,
      [this._compressionType = STORE]) {
    name = name.replaceAll('\\', '/');
    if (content is List<int>) {
      _content = content;
      _rawContent = InputStream(_content);
    } else if (content is InputStream) {
      _rawContent = InputStream.from(content);
    }
  }

  ArchiveFile.noCompress(this.name, this.size, dynamic content) {
    name = name.replaceAll('\\', '/');
    compress = false;
    if (content is List<int>) {
      _content = content;
      _rawContent = InputStream(_content);
    } else if (content is InputStream) {
      _rawContent = InputStream.from(content);
    }
  }

  ArchiveFile.stream(this.name, this.size, dynamic content_stream) {
    // Paths can only have / path separators
    name = name.replaceAll('\\', '/');
    compress = true;
    _content = content_stream;
    //_rawContent = content_stream;
    _compressionType = STORE;
  }

  /// Get the content of the file, decompressing on demand as necessary.
  dynamic get content {
    if (_content == null) {
      decompress();
    }
    return _content;
  }

  /// If the file data is compressed, decompress it.
  void decompress() {
    if (_content == null && _rawContent != null) {
      if (_compressionType == DEFLATE) {
        _content = Inflate.buffer(_rawContent!, size).getBytes();
      } else {
        _content = _rawContent!.toUint8List();
      }
      _compressionType = STORE;
    }
  }

  /// Is the data stored by this file currently compressed?
  bool get isCompressed => _compressionType != STORE;

  /// What type of compression is the raw data stored in
  int? get compressionType => _compressionType;

  /// Get the content without decompressing it first.
  InputStream? get rawContent => _rawContent;

  @override
  String toString() => name;

  int? _compressionType;
  InputStream? _rawContent;
  dynamic _content;
}

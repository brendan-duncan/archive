import 'dart:convert';
import 'dart:typed_data';

import '../util/file_content.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import './compression_type.dart';

/// A callback function called when archive entries are read from or written
/// to archive files like zip or tar.
typedef ArchiveCallback = void Function(ArchiveFile entry);

/// A file contained in an Archive.
class ArchiveFile {
  /// The name of the file or directory.
  String name;

  /// The access mode of the file or directory.
  int mode;

  /// The owner id of the file or directory.
  int ownerId = 0;

  /// The group id of the file or directory.
  int groupId = 0;

  /// The creation timestamp of the file or directory, in seconds from
  /// epoch.
  int creationTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The timestamp the file or directory was last modified, in seconds since
  /// epoch.
  late int lastModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// If symbolicLink is not null, the entry is a symbolic link and this is
  /// the path to what it's linking to. This should be an archive relative path.
  /// Symlinks pointing outside of the archive will be invalid when extracting
  /// archives to disk.
  String? symbolicLink;

  /// True if the entry is a symbolic link, otherwise false.
  bool get isSymbolicLink => symbolicLink?.isNotEmpty ?? false;

  /// The crc32 checksum of the uncompressed content.
  int? crc32;

  /// An optional comment for the archive entry.
  String? comment;

  /// The type of compression to use when encoding an archive.
  /// If this is not set, the default compression type will be used.
  /// For a zip file, this is deflate compression.
  /// This value is set when decoding a zip to the method of compression
  /// the file was stored in the zip file. It does not indicate the current
  /// compression of the file's content, it is only used for how the file
  /// should be compressed when encoding a zip.
  CompressionType? compression;

  /// The level of compression to use when encoding an archive.
  /// If this is not set, the default level of compression will be used.
  /// This value is only used for encoding an archive, allowing you to control
  /// the compression level of individual files in an archive. It is not set
  /// when decoding an archive.
  int? compressionLevel;

  FileContent? _rawContent;
  FileContent? _content;

  /// The size of the file, in bytes. This is set when decoding an archive,
  /// it isn't used for encoding.
  int size = 0;

  /// If false, the file represents a directory.
  bool isFile = true;

  /// If true, the file represents a directory.
  bool get isDirectory => !isFile;

  /// The unix permission flags of the file.
  int get unixPermissions => mode & 0x1ff;

  /// Alias for ArchiveFile.bytes for backwards compatibility.
  ArchiveFile(this.name, this.size, List<int> data) : mode = 0x1a4 {
    _content = FileContentMemory(data);
    _rawContent = FileContentMemory(data);
  }

  /// A file storing the given [data].
  ArchiveFile.bytes(this.name, List<int> data) : mode = 0x1a4 {
    _content = FileContentMemory(data);
    _rawContent = FileContentMemory(data);
    size = data.length;
  }

  /// A file storing the given [data].
  factory ArchiveFile.typedData(String name, TypedData data) =>
      ArchiveFile.bytes(name,
          Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes));

  /// A file storing the given string data [content].
  ArchiveFile.string(this.name, String content) : mode = 0x1a4 {
    final bytes = utf8.encode(content);
    size = bytes.length;
    _content = FileContentMemory(bytes);
    _rawContent = FileContentMemory(bytes);
  }

  /// A file that gets its content from the given [stream].
  ArchiveFile.stream(this.name, InputStream stream) : mode = 0x1a4 {
    size = stream.length;
    _rawContent = FileContentStream(stream);
  }

  /// A file that gets its content from the given [file].
  ArchiveFile.file(this.name, this.size, FileContent file) : mode = 0x1a4 {
    _rawContent = file;
  }

  /// A file that's a symlink to another file.
  ArchiveFile.symlink(this.name, String symbolicLink) : mode = 0x1a4 {
    this.symbolicLink = symbolicLink;
  }

  /// An empty file.
  ArchiveFile.noData(this.name) : mode = 0x1a4;

  /// A directory, usually representing an empty directory in an archive.
  ArchiveFile.directory(this.name)
      : mode = 0x1a4,
        isFile = false;

  /// Helper constructor to define a file storing the given [data], which
  /// remains uncompressed in the archive.
  ArchiveFile.noCompress(this.name, this.size, List<int> data) : mode = 0x1a4 {
    _content = FileContentMemory(data);
    _rawContent = FileContentMemory(data);
    compression = CompressionType.none;
  }

  DateTime get lastModDateTime {
    int year = ((lastModTime >> 25) & 0x7f) + 1980;
    int month = ((lastModTime >> 21) & 0x0f);
    int day = (lastModTime >> 16) & 0x1f;
    int hours = (lastModTime >> 11) & 0x1f;
    int minutes = (lastModTime >> 5) & 0x3f;
    int seconds = (lastModTime << 1) & 0x3e;
    return DateTime.utc(year, month, day, hours, minutes, seconds);
  }

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

  static final _emptyData = Uint8List(0);

  /// Alias to [readBytes], kept for backwards compatibility.
  Uint8List get content => readBytes() ?? _emptyData;

  /// Clear the used memory and asynchronously close the underlying file handle.
  Future<void> close() async {
    final futures = <Future<void>>[];
    if (_content != null) {
      futures.add(_content!.close());
    }
    if (_rawContent != null) {
      futures.add(_rawContent!.close());
      _content = null;
    }

    await Future.wait(futures);
  }

  /// Clear the used memory and close the underlying file handle.
  void closeSync() {
    _content?.closeSync();
    _rawContent?.closeSync();
    _content = null;
  }

  /// Clears the memory used without closing the underlying file handle.
  void clear() {
    _rawContent = null;
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

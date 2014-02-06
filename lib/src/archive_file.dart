part of archive;

/**
 * A file contained in an Archive.
 */
class ArchiveFile {
  static const int STORE = 0;
  static const int DEFLATE = 8;

  String name;
  /// The uncompressed size of the file
  int size;
  int mode;
  int ownerId = 0;
  int groupId = 0;
  int lastModTime;
  /// The crc32 checksum of the uncompressed content.
  int crc32;
  String comment;

  ArchiveFile(this.name, this.size, this._content,
              [this._compressionType = STORE]);

  /**
   * Get the content of the file, decompressing on demand as necessary.
   */
  List<int> get content {
    if (_compressionType == DEFLATE) {
      _content = new Inflate(_content).getBytes();
      _compressionType = STORE;
    }
    return _content;
  }

  /**
   * Is the data stored by this file currently compressed?
   */
  bool get isCompressed => _compressionType != STORE;

  int get compressionType => _compressionType;

  /**
   * Get the content without decompressing it first.
   */
  List<int> get rawContent => _content;

  String toString() => name;

  int _compressionType;
  List<int> _content;
}

part of archive;

class File {
  static const int UNCOMPRESSED = 0;
  static const int DEFLATE = 1;

  String filename;
  int fileSize;
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int lastModTime = 0; // 12 bytes

  File(this.filename, this.fileSize, this._content,
       [this._compressionType = UNCOMPRESSED]);

  /**
   * Get the contents of the file, decompressing on demand as necessary.
   */
  List<int> get content {
    if (_compressionType == DEFLATE) {
      if (_decompressed == null) {
        print('DECOMPRESSING $filename / ${_content.length}');
        _decompressed = new Inflate(new InputBuffer(_content)).getBytes();
        _content = null;
      }
      return _decompressed;
    }

    return _content;
  }

  int _compressionType;
  List<int> _content;
  List<int> _decompressed;
}

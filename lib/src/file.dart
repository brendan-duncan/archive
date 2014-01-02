part of archive;

class File {
  static const int STORE = 0;
  static const int DEFLATE = 8;

  String filename;
  int fileSize;
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int lastModTime = 0; // 12 bytes

  File(this.filename, this.fileSize, this._content,
       [this._compressionType = STORE]);

  /**
   * Get the contents of the file, decompressing on demand as necessary.
   */
  List<int> get content {
    if (_compressionType == DEFLATE) {
      _content = new Inflate(new InputBuffer(_content)).getBytes();
      _compressionType = STORE;
    }
    return _content;
  }

  String toString() => filename;

  int _compressionType;
  List<int> _content;
}

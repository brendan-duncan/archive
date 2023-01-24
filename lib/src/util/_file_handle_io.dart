import 'dart:io';
import 'dart:typed_data';

class FileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  int _length;

  FileHandle(this._path)
      : _position = 0,
        _length = 0;

  bool open() {
    if (_file != null) {
      return true;
    }
    _file = File(_path).openSync();
    _length = _file?.lengthSync() ?? 0;
    _position = 0;
    return _file != null;
  }

  String get path => _path;

  int get position => _position;

  int get length => _length;

  bool get isOpen => _file != null;

  void setPosition(int p) {
    if (_file == null || p == _position) {
      return;
    }
    _position = p;
    _file!.setPositionSync(p);
  }

  void close() {
    if (_file == null) {
      return;
    }
    final fp = _file;
    _file = null;
    _position = 0;
    fp!.closeSync();
  }

  int readInto(Uint8List buffer, [int? end]) {
    if (_file == null) {
      open();
    }
    final size = _file!.readIntoSync(buffer, 0, end);
    _position += size;
    return size;
  }
}

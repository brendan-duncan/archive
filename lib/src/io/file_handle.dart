import 'dart:io';
import 'dart:typed_data';

class FileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  late int _length;

  FileHandle(this._path)
      : _file = File(_path).openSync(),
        _position = 0 {
    _length = _file!.lengthSync();
  }

  String get path => _path;

  int get position => _position;

  set position(int p) {
    if (_file == null || p == _position) {
      return;
    }
    _position = p;
    _file!.setPositionSync(p);
  }

  int get length => _length;

  bool get isOpen => _file != null;

  Future<void> close() async {
    if (_file == null) {
      return;
    }
    var fp = _file!;
    _file = null;
    _position = 0;
    await fp.close();
  }

  void closeSync() {
    if (_file == null) {
      return;
    }
    var fp = _file!;
    _file = null;
    _position = 0;
    fp.closeSync();
  }

  void open() {
    if (_file != null) {
      return;
    }

    _file = File(_path).openSync();
    _position = 0;
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

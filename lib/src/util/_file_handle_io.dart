import 'dart:io';
import 'dart:typed_data';

class FileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  int _length;

  FileHandle(this._path)
      : _position = 0
      , _length = 0;

  Future<bool> open() async {
    if (_file != null) {
      return true;
    }
    _file = await File(_path).open();
    _length = await _file?.length() ?? 0;
    _position = 0;
    return _file != null;
  }

  String get path => _path;

  int get position => _position;

  int get length => _length;

  bool get isOpen => _file != null;

  Future<void> setPosition(int p) async {
    if (_file == null || p == _position) {
      return;
    }
    _position = p;
    await _file!.setPosition(p);
  }

  Future<void> close() async {
    if (_file == null) {
      return;
    }
    final fp = _file;
    _file = null;
    _position = 0;
    await fp!.close();
  }

  Future<int> readInto(Uint8List buffer, [int? end]) async {
    if (_file == null) {
      await open();
    }
    final size = await _file!.readInto(buffer, 0, end);
    _position += size;
    return size;
  }
}

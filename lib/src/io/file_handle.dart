import 'dart:io';
import 'dart:typed_data';

abstract class AbstractFileHandle {
  int get position ;
  set position(int p);
  int get length ;
  bool get isOpen;
  Future<void> close();
  void open() ;
  int readInto(Uint8List buffer, [int? end]) ;
}

class FileHandle extends AbstractFileHandle {
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

  @override
  int get position => _position;

  @override
  set position(int p) {
    if (_file == null || p == _position) {
      return;
    }
    _position = p;
    _file!.setPositionSync(p);
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _file != null;

  @override
  Future<void> close() async {
    if (_file == null) {
      return;
    }
    var fp = _file;
    _file = null;
    _position = 0;
    await fp!.close();
  }

  @override
  void open() {
    if (_file != null) {
      return;
    }

    _file = File(_path).openSync();
    _position = 0;
  }

  @override
  int readInto(Uint8List buffer, [int? end]) {
    if (_file == null) {
      open();
    }
    final size = _file!.readIntoSync(buffer, 0, end);
    _position += size;
    return size;
  }
}

//TODO add a RAM-based file handle implementation
// class RAMFileHandle extends AbstractFileHandle {
//   // IMPLEMENTATION TODO
// }

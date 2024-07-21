import 'dart:io';
import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'file_access.dart';

class FileHandle extends AbstractFileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  int _length;

  FileHandle(this._path, {FileAccess mode = FileAccess.read})
      : _position = 0,
        _length = 0,
        super() {
    if (mode != FileAccess.closed) {
      open(mode: mode);
    }
  }

  @override
  bool open({FileAccess mode = FileAccess.read}) {
    if (_file != null) {
      return true;
    }
    if (mode == FileAccess.closed) {
      return false;
    }
    final fileMode = mode == FileAccess.read ? FileMode.read : FileMode.write;
    final fp = File(path);
    if (mode == FileAccess.write) {
      fp.createSync(recursive: true);
    }
    _file = fp.openSync(mode: fileMode);
    _length = _file?.lengthSync() ?? 0;
    _position = 0;
    return _file != null;
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
    final fp = _file;
    _file = null;
    _position = 0;
    await fp!.close();
  }

  @override
  void closeSync() {
    if (_file == null) {
      return;
    }
    final fp = _file;
    _file = null;
    _position = 0;
    fp!.closeSync();
  }

  @override
  int readInto(Uint8List buffer, [int? length]) {
    if (_file == null) {
      open();
    }
    final size = _file!.readIntoSync(buffer, 0, length);
    _position += size;
    return size;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if (_file == null) {
      open();
    }
    final int size;
    if (end == null) {
      size = buffer.length;
    } else {
      size = end - start;
    }
    _file!.writeFromSync(buffer, start, end);
    _position += size;
  }
}

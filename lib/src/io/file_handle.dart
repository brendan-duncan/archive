import 'dart:io';
import 'dart:typed_data';

import '../util/abstract_file_handle.dart';

class FileHandle extends AbstractFileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  late int _length;

  FileHandle.fromFile(File fp,
      {AbstractFileOpenMode openMode = AbstractFileOpenMode.read})
      : _position = 0,
        _path = "",
        super(openMode) {
    final FileMode fileOpenMode;
    switch (openMode) {
      case AbstractFileOpenMode.read:
        fileOpenMode = FileMode.read;
        break;
      case AbstractFileOpenMode.write:
        fileOpenMode = FileMode.write;
        break;
    }
    _file = fp.openSync(mode: fileOpenMode);
    _length = _file?.lengthSync() ?? 0;
  }

  FileHandle.from(RandomAccessFile fp)
      : _position = 0,
        _path = "",
        super(AbstractFileOpenMode.read) {
    _file = fp;
    _length = fp.lengthSync();
  }

  FileHandle(
    this._path, {
    AbstractFileOpenMode openMode = AbstractFileOpenMode.read,
  })  : _position = 0,
        super(openMode) {
    if (openMode == AbstractFileOpenMode.write) {
      File(_path).createSync(recursive: true);
    }
    _open();
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
    var fp = _file!;
    _file = null;
    _position = 0;
    await fp.close();
  }

  @override
  void closeSync() {
    if (_file == null) {
      return;
    }
    var fp = _file!;
    _file = null;
    _position = 0;
    fp.closeSync();
  }

  void _open() {
    if (_file != null) {
      return;
    }

    final FileMode fileOpenMode;
    switch (openMode) {
      case AbstractFileOpenMode.read:
        fileOpenMode = FileMode.read;
        break;
      case AbstractFileOpenMode.write:
        fileOpenMode = FileMode.write;
        break;
    }
    _file = File(_path).openSync(mode: fileOpenMode);
    _position = 0;
  }

  @override
  int readInto(Uint8List buffer, [int? end]) {
    if (_file == null) {
      _open();
    }
    final size = _file!.readIntoSync(buffer, 0, end);
    _position += size;
    return size;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if (_file == null) {
      _open();
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

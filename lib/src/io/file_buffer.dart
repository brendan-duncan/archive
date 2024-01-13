import 'dart:math';
import 'dart:typed_data';

import '../util/abstract_file_handle.dart';
import '../util/byte_order.dart';

class FileBuffer {
  final int byteOrder;
  final AbstractFileHandle _file;
  late Uint8List _buffer;
  int _fileSize = 0;
  int _position = 0;
  int _bufferSize = 0;

  /// The buffer size should be at least 8 bytes, so reading a 64-bit value doesn't
  /// have to deal with buffer overflow.
  static const int kMinBufferSize = 8;
  static const int kDefaultBufferSize = 1024 * 1024; // 1MB

  FileBuffer(
    this._file, {
    this.byteOrder = LITTLE_ENDIAN,
    int bufferSize = kDefaultBufferSize,
  }) {
    _fileSize = _file.length;
    // Prevent having a buffer smaller than the minimum buffer size
    _bufferSize = max(
      // If possible, avoid having a buffer bigger than the file itself
      min(bufferSize, _fileSize),
      kMinBufferSize,
    );
    _buffer = Uint8List(_bufferSize);
    _readBuffer(0, _fileSize);
  }

  int get length => _fileSize;

  Future<void> close() async {
    await _file.close();
    _fileSize = 0;
    _position = 0;
  }

  void closeSync() {
    _file.closeSync();
    _fileSize = 0;
    _position = 0;
  }

  void reset() {
    _position = 0;
  }

  int readUint8(int position, int fileSize) {
    if (position >= _fileSize || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + _bufferSize)) {
      _readBuffer(position, fileSize);
    }
    var p = position - _position;
    return _buffer[p];
  }

  int readUint16(int position, int fileSize) {
    if (position >= (_fileSize - 2) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 2))) {
      _readBuffer(position, fileSize);
    }
    var p = position - _position;
    final b1 = _buffer[p++];
    final b2 = _buffer[p++];
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  int readUint24(int position, int fileSize) {
    if (position >= (_fileSize - 3) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 3))) {
      _readBuffer(position, fileSize);
    }
    var p = position - _position;
    final b1 = _buffer[p++];
    final b2 = _buffer[p++];
    final b3 = _buffer[p++];
    if (byteOrder == BIG_ENDIAN) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  int readUint32(int position, int fileSize) {
    if (position >= (_fileSize - 4) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 4))) {
      _readBuffer(position, fileSize);
    }
    var p = position - _position;
    final b1 = _buffer[p++];
    final b2 = _buffer[p++];
    final b3 = _buffer[p++];
    final b4 = _buffer[p++];
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  int readUint64(int position, int fileSize) {
    if (position >= (_fileSize - 8) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 8))) {
      _readBuffer(position, fileSize);
    }
    var p = position - _position;
    final b1 = _buffer[p++];
    final b2 = _buffer[p++];
    final b3 = _buffer[p++];
    final b4 = _buffer[p++];
    final b5 = _buffer[p++];
    final b6 = _buffer[p++];
    final b7 = _buffer[p++];
    final b8 = _buffer[p++];

    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 56) |
          (b2 << 48) |
          (b3 << 40) |
          (b4 << 32) |
          (b5 << 24) |
          (b6 << 16) |
          (b7 << 8) |
          b8;
    }
    return (b8 << 56) |
        (b7 << 48) |
        (b6 << 40) |
        (b5 << 32) |
        (b4 << 24) |
        (b3 << 16) |
        (b2 << 8) |
        b1;
  }

  Uint8List readBytes(int position, int count, int fileSize) {
    if (count > _buffer.length) {
      if (position + count >= _fileSize) {
        count = _fileSize - position;
      }
      final bytes = Uint8List(count);
      _file.position = position;
      _file.readInto(bytes);
      return bytes;
    }

    if (position < _position ||
        (position + count) >= (_position + _bufferSize)) {
      _readBuffer(position, fileSize);
    }

    final start = position - _position;
    final bytes = _buffer.sublist(start, start + count);
    return bytes;
  }

  void _readBuffer(int position, int fileSize) {
    _file.position = position;
    final size = min(fileSize, _buffer.length);
    _bufferSize = _file.readInto(_buffer, size);
    _position = position;
  }
}

import 'dart:math';
import 'dart:typed_data';

import 'byte_order.dart';
import 'file_handle.dart';
import 'input_stream.dart';

class InputStreamFile extends InputStream {
  final String path;
  final FileHandle _file;
  int _fileOffset = 0;
  int _fileSize = 0;
  int _position = 0;
  int _bufferSize = 0;
  int _bufferPosition = 0;
  Uint8List? _buffer;

  static const int defaultBufferSize = 4096;

  InputStreamFile(this.path,
      {super.byteOrder = ByteOrder.littleEndian,
      int bufferSize = defaultBufferSize})
      : _file = FileHandle(path) {
    // Don't have a buffer bigger than the file itself.
    // Also, make sure it's at least 8 bytes, so reading a 64-bit value doesn't
    // have to deal with buffer overflow.
    _bufferSize = max(min(bufferSize, _fileSize), 8);
  }

  InputStreamFile.from(InputStreamFile other, {int? position, int? length})
      : path = other.path,
        _file = other._file,
        _fileOffset = other._fileOffset + (position ?? 0),
        _fileSize = length ?? other._fileSize,
        _bufferSize = other.bufferSize,
        super(byteOrder: other.byteOrder);

  @override
  bool open() {
    _file.open();
    _fileSize = _file.length;
    return _file.isOpen;
  }

  @override
  void close() {
    _file.close();
    _fileSize = 0;
    _position = 0;
    _buffer = null;
  }

  @override
  int get length => _fileSize;

  @override
  int get position => _position;

  @override
  bool get isEOS => _position >= _fileSize;

  int get bufferSize => _bufferSize;

  int get bufferPosition => _bufferPosition;

  int get bufferRemaining => _bufferSize - _bufferPosition;

  int get fileRemaining => _fileSize - _position;

  @override
  void setPosition(int v) {
    if (v == _position) {
      return;
    }
    if (v < _position) {
      rewind(_position - v);
    } else if (v > _position) {
      skip(v - _position);
    }
  }

  @override
  void reset() {
    _position = 0;
    return _readBuffer();
  }

  @override
  void skip(int length) {
    if (_buffer == null) {
      _position += length;
      _position = _position.clamp(0, _fileSize);
      return;
    }

    if ((_bufferPosition + length) < _bufferSize) {
      _bufferPosition += length;
      _position += length;
    } else {
      _position += length;
      _readBuffer();
    }
  }

  @override
  InputStream subset({int? position, int? length}) =>
      InputStreamFile.from(this, position: position, length: length);

  @override
  void rewind([int length = 1]) {
    if (_buffer == null) {
      _position -= length;
      _position = _position.clamp(0, _fileSize);
      return;
    }

    if ((_bufferPosition - length) < 0) {
      _position = max(_position - length, 0);
      _readBuffer();
      return;
    }
    _bufferPosition -= length;
    _position -= length;
  }

  @override
  int readByte() {
    if (isEOS) {
      return 0;
    }

    if (_buffer == null || _bufferPosition >= _bufferSize) {
      _readBuffer();
    }

    if (_bufferPosition >= _bufferSize) {
      return 0;
    }

    _position++;
    return _buffer![_bufferPosition++] & 0xff;
  }

  @override
  InputStream readBytes(int count) {
    count = min(count, fileRemaining);
    final bytes =
        InputStreamFile.from(this, position: _position, length: count);
    skip(count);
    return bytes;
  }

  @override
  Uint8List toUint8List() {
    if (isEOS) {
      return Uint8List(0);
    }

    final length = fileRemaining;
    final bytes = Uint8List(length);

    _file.position = _fileOffset + _position;
    final readBytes = _file.readInto(bytes);

    skip(length);
    if (readBytes != bytes.length) {
      bytes.length = readBytes;
    }

    return bytes;
  }

  void _readBuffer() {
    _bufferPosition = 0;
    _buffer ??= Uint8List(min(_bufferSize, _fileSize));

    _file.position = _fileOffset + _position;
    _bufferSize = _file.readInto(_buffer!, _buffer!.length);
  }
}

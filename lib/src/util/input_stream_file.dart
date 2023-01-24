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
  Future<bool> open() async {
    await _file.open();
    _fileSize = _file.length;
    return _file.isOpen;
  }

  @override
  Future<void> close() async {
    await _file.close();
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
  Future<void> setPosition(int v) async {
    if (v == _position) {
      return;
    }
    if (v < _position) {
      await rewind(_position - v);
    } else if (v > _position) {
      await skip(v - _position);
    }
  }

  @override
  Future<void> reset() async {
    _position = 0;
    return _readBuffer();
  }

  @override
  Future<void> skip(int length) async {
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
      await _readBuffer();
    }
  }

  @override
  Future<InputStream> subset({int? position, int? length}) async =>
      InputStreamFile.from(this, position: position, length: length);

  @override
  Future<void> rewind([int length = 1]) async {
    if (_buffer == null) {
      _position -= length;
      _position = _position.clamp(0, _fileSize);
      return;
    }

    if ((_bufferPosition - length) < 0) {
      _position = max(_position - length, 0);
      await _readBuffer();
      return;
    }
    _bufferPosition -= length;
    _position -= length;
  }

  @override
  Future<int> readByte() async {
    if (isEOS) {
      return 0;
    }

    if (_buffer == null || _bufferPosition >= _bufferSize) {
      await _readBuffer();
    }

    if (_bufferPosition >= _bufferSize) {
      return 0;
    }

    _position++;
    return _buffer![_bufferPosition++] & 0xff;
  }

  @override
  Future<InputStream> readBytes(int count) async {
    count = min(count, fileRemaining);
    final bytes =
        InputStreamFile.from(this, position: _position, length: count);
    await skip(count);
    return bytes;
  }

  @override
  Future<Uint8List> toUint8List() async {
    if (isEOS) {
      return Uint8List(0);
    }

    final length = fileRemaining;
    final bytes = Uint8List(length);

    await _file.setPosition(_fileOffset + _position);
    final readBytes = await _file.readInto(bytes);

    await skip(length);
    if (readBytes != bytes.length) {
      bytes.length = readBytes;
    }

    return bytes;
  }

  Future<void> _readBuffer() async {
    _bufferPosition = 0;
    _buffer ??= Uint8List(min(_bufferSize, _fileSize));

    await _file.setPosition(_fileOffset + _position);
    _bufferSize = await _file.readInto(_buffer!, _buffer!.length);
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../util/archive_exception.dart';
import '../util/byte_order.dart';
import '../util/input_stream.dart';

class InputFileStream extends InputStreamBase {
  final String path;
  final RandomAccessFile _file;
  final int byteOrder;
  int _fileSize = 0;
  final List<int> _buffer;

  int _filePosition = 0;
  int _bufferSize = 0;
  int _bufferPosition = 0;

  static const int _kDefaultBufferSize = 4096;

  InputFileStream(String path,
      {this.byteOrder = LITTLE_ENDIAN, int bufferSize = _kDefaultBufferSize})
      : path = path,
        _file = File(path).openSync(),
        _buffer = Uint8List(bufferSize) {
    _fileSize = _file.lengthSync();
    _readBuffer();
  }

  InputFileStream.file(File file,
      {this.byteOrder = LITTLE_ENDIAN, int bufferSize = _kDefaultBufferSize})
      : path = file.path,
        _file = file.openSync(),
        _buffer = Uint8List(bufferSize) {
    _fileSize = _file.lengthSync();
    _readBuffer();
  }

  void close() {
    _file.closeSync();
    _fileSize = 0;
  }

  @override
  int get length => _fileSize;

  @override
  int get position => _filePosition;

  @override
  bool get isEOS =>
      (_filePosition >= _fileSize) && (_bufferPosition >= _bufferSize);

  int get bufferSize => _bufferSize;

  int get bufferPosition => _bufferPosition;

  int get bufferRemaining => _bufferSize - _bufferPosition;

  int get fileRemaining => _fileSize - _filePosition;

  @override
  void reset() {
    _filePosition = 0;
    _file.setPositionSync(0);
    _readBuffer();
  }

  @override
  void skip(int length) {
    if ((_bufferPosition + length) < _bufferSize) {
      _bufferPosition += length;
    } else {
      var remaining = length - (_bufferSize - _bufferPosition);
      while (!isEOS) {
        _readBuffer();
        if (remaining < _bufferSize) {
          _bufferPosition += remaining;
          break;
        }
        remaining -= _bufferSize;
      }
    }
  }

  /// Read [count] bytes from an [offset] of the current read position, without
  /// moving the read position.
  @override
  InputStream peekBytes(int count, [int offset = 0]) {
    var end = _bufferPosition + offset + count;
    if (end > 0 && end < _bufferSize) {
      final bytes = _buffer.sublist(_bufferPosition + offset, end);
      return InputStream(bytes);
    }

    final bytes = Uint8List(count);

    var remaining = _bufferSize - (_bufferPosition + offset);
    if (remaining > 0) {
      final bytes1 = _buffer.sublist(_bufferPosition + offset, _bufferSize);
      bytes.setRange(0, remaining, bytes1);
    }

    _file.readIntoSync(bytes, remaining, count);
    _file.setPositionSync(_filePosition);

    return InputStream(bytes);
  }

  @override
  void rewind([int count = 1]) {
    if (_bufferPosition - count < 0) {
      var remaining = (_bufferPosition - count).abs();
      _filePosition = _filePosition - _bufferSize - remaining;
      if (_filePosition < 0) {
        _filePosition = 0;
      }
      _file.setPositionSync(_filePosition);
      _readBuffer();
      return;
    }
    _bufferPosition -= count;
  }

  @override
  int readByte() {
    if (isEOS) {
      return 0;
    }
    if (_bufferPosition >= _bufferSize) {
      _readBuffer();
    }
    if (_bufferPosition >= _bufferSize) {
      return 0;
    }
    return _buffer[_bufferPosition++] & 0xff;
  }

  /// Read a 16-bit word from the stream.
  @override
  int readUint16() {
    var b1 = 0;
    var b2 = 0;
    if ((_bufferPosition + 2) < _bufferSize) {
      b1 = _buffer[_bufferPosition++] & 0xff;
      b2 = _buffer[_bufferPosition++] & 0xff;
    } else {
      b1 = readByte();
      b2 = readByte();
    }
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  /// Read a 24-bit word from the stream.
  @override
  int readUint24() {
    var b1 = 0;
    var b2 = 0;
    var b3 = 0;
    if ((_bufferPosition + 3) < _bufferSize) {
      b1 = _buffer[_bufferPosition++] & 0xff;
      b2 = _buffer[_bufferPosition++] & 0xff;
      b3 = _buffer[_bufferPosition++] & 0xff;
    } else {
      b1 = readByte();
      b2 = readByte();
      b3 = readByte();
    }

    if (byteOrder == BIG_ENDIAN) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  /// Read a 32-bit word from the stream.
  @override
  int readUint32() {
    var b1 = 0;
    var b2 = 0;
    var b3 = 0;
    var b4 = 0;
    if ((_bufferPosition + 4) < _bufferSize) {
      b1 = _buffer[_bufferPosition++] & 0xff;
      b2 = _buffer[_bufferPosition++] & 0xff;
      b3 = _buffer[_bufferPosition++] & 0xff;
      b4 = _buffer[_bufferPosition++] & 0xff;
    } else {
      b1 = readByte();
      b2 = readByte();
      b3 = readByte();
      b4 = readByte();
    }

    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /// Read a 64-bit word form the stream.
  @override
  int readUint64() {
    var b1 = 0;
    var b2 = 0;
    var b3 = 0;
    var b4 = 0;
    var b5 = 0;
    var b6 = 0;
    var b7 = 0;
    var b8 = 0;
    if ((_bufferPosition + 8) < _bufferSize) {
      b1 = _buffer[_bufferPosition++] & 0xff;
      b2 = _buffer[_bufferPosition++] & 0xff;
      b3 = _buffer[_bufferPosition++] & 0xff;
      b4 = _buffer[_bufferPosition++] & 0xff;
      b5 = _buffer[_bufferPosition++] & 0xff;
      b6 = _buffer[_bufferPosition++] & 0xff;
      b7 = _buffer[_bufferPosition++] & 0xff;
      b8 = _buffer[_bufferPosition++] & 0xff;
    } else {
      b1 = readByte();
      b2 = readByte();
      b3 = readByte();
      b4 = readByte();
      b5 = readByte();
      b6 = readByte();
      b7 = readByte();
      b8 = readByte();
    }

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

  @override
  InputStream readBytes(int length) {
    if (isEOS) {
      return InputStream(<int>[]);
    }

    if (_bufferPosition == _bufferSize) {
      _readBuffer();
    }

    if (_remainingBufferSize >= length) {
      final bytes = _buffer.sublist(_bufferPosition, _bufferPosition + length);
      _bufferPosition += length;
      return InputStream(bytes);
    }

    var total_remaining = fileRemaining + _remainingBufferSize;
    if (length > total_remaining) {
      length = total_remaining;
    }

    final bytes = Uint8List(length);

    var offset = 0;
    while (length > 0) {
      var remaining = _bufferSize - _bufferPosition;
      var end = (length > remaining) ? _bufferSize : (_bufferPosition + length);
      final l = _buffer.sublist(_bufferPosition, end);
      // TODO probably better to use bytes.setRange here.
      for (var i = 0; i < l.length; ++i) {
        bytes[offset + i] = l[i];
      }
      offset += l.length;
      length -= l.length;
      _bufferPosition = end;
      if (length > 0 && _bufferPosition == _bufferSize) {
        _readBuffer();
        if (_bufferSize == 0) {
          break;
        }
      }
    }

    return InputStream(bytes);
  }

  @override
  Uint8List toUint8List() {
    var bytes = readBytes(_fileSize);
    return bytes.toUint8List();
  }

  /// Read a null-terminated string, or if [len] is provided, that number of
  /// bytes returned as a string.
  @override
  String readString({int? size, bool utf8 = true}) {
    if (size == null) {
      final codes = <int>[];
      while (!isEOS) {
        var c = readByte();
        if (c == 0) {
          return utf8
              ? Utf8Decoder().convert(codes)
              : String.fromCharCodes(codes);
        }
        codes.add(c);
      }
      throw ArchiveException('EOF reached without finding string terminator');
    }

    final s = readBytes(size);
    final bytes = s.toUint8List();
    final str =
        utf8 ? Utf8Decoder().convert(bytes) : String.fromCharCodes(bytes);
    return str;
  }

  int get _remainingBufferSize => _bufferSize - _bufferPosition;

  void _readBuffer() {
    _bufferPosition = 0;
    _bufferSize = _file.readIntoSync(_buffer);
    if (_bufferSize == 0) {
      return;
    }
    _filePosition += _bufferSize;
  }
}

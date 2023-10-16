import 'dart:convert';
import 'dart:typed_data';

import 'file_buffer.dart';
import '../util/archive_exception.dart';
import '../util/byte_order.dart';
import '../util/input_stream.dart';

class InputFileStream extends InputStreamBase {
  final String path;
  final int byteOrder;
  final FileBuffer _file;
  final int _fileOffset;
  late int _fileSize;
  int _position;

  InputFileStream(this.path,
      {this.byteOrder = LITTLE_ENDIAN,
      int bufferSize = FileBuffer.kDefaultBufferSize})
      : _file = FileBuffer(path),
        _fileOffset = 0,
        _position = 0 {
    _fileSize = _file.length;
  }

  InputFileStream.clone(InputFileStream other, {int? position, int? length})
      : path = other.path,
        byteOrder = other.byteOrder,
        _file = other._file,
        _fileOffset = other._fileOffset + (position ?? 0),
        _fileSize = length ?? other._fileSize,
        _position = 0;

  @override
  Future<void> close() async {
    await _file.close();
    _position = 0;
    _fileSize = 0;
  }

  @override
  closeSync() {
    _file.closeSync();
    _position = 0;
    _fileSize = 0;
  }

  @override
  int get length => _fileSize;

  @override
  int get position => _position;

  @override
  set position(int v) {
    if (v < _position) {
      rewind(_position - v);
    } else if (v > _position) {
      skip(v - _position);
    }
  }

  @override
  bool get isEOS => _position >= _fileSize;

  int get fileRemaining => _fileSize - _position;

  @override
  void reset() {
    _position = 0;
  }

  @override
  void skip(int length) {
    _position += length;
  }

  @override
  void rewind([int length = 1]) {
    _position -= length;
    if (_position < 0) {
      _position = 0;
    }
  }

  @override
  InputStreamBase subset([int? position, int? length]) {
    return InputFileStream.clone(this, position: position, length: length);
  }

  /// Read [count] bytes from an [offset] of the current read position, without
  /// moving the read position.
  @override
  InputStreamBase peekBytes(int count, [int offset = 0]) {
    return subset(_position + offset, count);
  }

  @override
  int readByte() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint8(_fileOffset + _position, _fileSize);
    _position++;
    return b;
  }

  /// Read a 16-bit word from the stream.
  @override
  int readUint16() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint16(_fileOffset + _position, _fileSize);
    _position += 2;
    return b;
  }

  /// Read a 24-bit word from the stream.
  @override
  int readUint24() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint24(_fileOffset + _position, _fileSize);
    _position += 3;
    return b;
  }

  /// Read a 32-bit word from the stream.
  @override
  int readUint32() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint32(_fileOffset + _position, _fileSize);
    _position += 4;
    return b;
  }

  /// Read a 64-bit word form the stream.
  @override
  int readUint64() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint64(_fileOffset + _position, _fileSize);
    _position += 8;
    return b;
  }

  @override
  InputStreamBase readBytes(int count) {
    if (isEOS) {
      return InputFileStream.clone(this, length: 0);
    }
    if ((_position + count) > _fileSize) {
      count = _fileSize - _position;
    }
    final bytes =
        InputFileStream.clone(this, position: _position, length: count);
    _position += bytes.length;
    return bytes;
  }

  @override
  Uint8List toUint8List([Uint8List? bytes]) {
    if (isEOS) {
      return Uint8List(0);
    }
    return _file.readBytes(_fileOffset + position, fileRemaining, _fileSize);
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

  FileBuffer get file => _file;
}

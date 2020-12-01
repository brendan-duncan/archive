import 'dart:typed_data';
import 'byte_order.dart';
import 'input_stream.dart';

abstract class OutputStreamBase {
  int get length;

  /// Write a byte to the output stream.
  void writeByte(int value);

  /// Write a set of bytes to the output stream.
  void writeBytes(List<int> bytes, [int? len]);

  /// Write an InputStream to the output stream.
  void writeInputStream(InputStreamBase bytes);

  /// Write a 16-bit word to the output stream.
  void writeUint16(int value);

  /// Write a 32-bit word to the end of the buffer.
  void writeUint32(int value);
}

class OutputStream extends OutputStreamBase {
  int _length;
  final int byteOrder;

  /// Create a byte buffer for writing.
  OutputStream({int? size = _BLOCK_SIZE, this.byteOrder = LITTLE_ENDIAN})
      : _buffer = Uint8List(size ?? _BLOCK_SIZE),
        _length = 0;

  @override
  int get length => _length;

  set length(int l) => _length = l;

  /// Get the resulting bytes from the buffer.
  List<int> getBytes() {
    return Uint8List.view(_buffer.buffer, 0, length);
  }

  /// Clear the buffer.
  void clear() {
    _buffer = Uint8List(_BLOCK_SIZE);
    length = 0;
  }

  /// Reset the buffer.
  void reset() {
    length = 0;
  }

  /// Write a byte to the end of the buffer.
  @override
  void writeByte(int value) {
    if (length == _buffer.length) {
      _expandBuffer();
    }
    _buffer[length++] = value & 0xff;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  void writeBytes(List<int> bytes, [int? len]) {
    len ??= bytes.length;

    while (length + len > _buffer.length) {
      _expandBuffer((length + len) - _buffer.length);
    }
    _buffer.setRange(length, length + len, bytes);
    length += len;
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    while (length + stream.length > _buffer.length) {
      _expandBuffer((length + stream.length) - _buffer.length);
    }

    if (stream is InputStream) {
      _buffer.setRange(
          length, length + stream.length, stream.buffer, stream.offset);
    } else {
      var bytes = stream.toUint8List();
      _buffer.setRange(length, length + stream.length, bytes, 0);
    }
    length += stream.length;
  }

  /// Write a 16-bit word to the end of the buffer.
  @override
  void writeUint16(int value) {
    if (byteOrder == BIG_ENDIAN) {
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  /// Write a 32-bit word to the end of the buffer.
  @override
  void writeUint32(int value) {
    if (byteOrder == BIG_ENDIAN) {
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  /// Return the subset of the buffer in the range [start:end].
  ///
  /// If [start] or [end] are < 0 then it is relative to the end of the buffer.
  /// If [end] is not specified (or null), then it is the end of the buffer.
  /// This is equivalent to the python list range operator.
  List<int> subset(int start, [int? end]) {
    if (start < 0) {
      start = (length) + start;
    }

    if (end == null) {
      end = length;
    } else if (end < 0) {
      end = length + end;
    }

    return Uint8List.view(_buffer.buffer, start, end - start);
  }

  /// Grow the buffer to accommodate additional data.
  void _expandBuffer([int? required]) {
    var blockSize = _BLOCK_SIZE;
    if (required != null) {
      if (required > blockSize) {
        blockSize = required;
      }
    }
    final newLength = (_buffer.length + blockSize) * 2;
    final newBuffer = Uint8List(newLength);
    newBuffer.setRange(0, _buffer.length, _buffer);
    _buffer = newBuffer;
  }

  static const _BLOCK_SIZE = 0x8000; // 32k block-size
  Uint8List _buffer;
}

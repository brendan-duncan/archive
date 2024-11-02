import 'dart:typed_data';

import 'byte_order.dart';
import 'input_memory_stream.dart';
import 'input_stream.dart';
import 'output_stream.dart';

class OutputMemoryStream extends OutputStream {
  @override
  int length;
  static const defaultBufferSize = 0x8000; // 32k block-size
  Uint8List _buffer;

  /// Create a byte buffer for writing.
  OutputMemoryStream(
      {int? size = defaultBufferSize, super.byteOrder = ByteOrder.littleEndian})
      : _buffer = Uint8List(size ?? defaultBufferSize),
        length = 0;

  @override
  void flush() {}

  /// Get the resulting bytes from the buffer.
  @override
  Uint8List getBytes() =>
      Uint8List.view(_buffer.buffer, _buffer.offsetInBytes, length);

  /// Clear the buffer.
  @override
  void clear() {
    _buffer = Uint8List(defaultBufferSize);
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
    _buffer[length++] = value;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;

    while (this.length + length > _buffer.length) {
      _expandBuffer((this.length + length) - _buffer.length);
    }
    _buffer.setRange(this.length, this.length + length, bytes);
    this.length += length;
  }

  @override
  void writeStream(InputStream stream) {
    while (length + stream.length > _buffer.length) {
      _expandBuffer((length + stream.length) - _buffer.length);
    }

    if (stream is InputMemoryStream) {
      if (stream.buffer != null) {
        _buffer.setRange(
            length, length + stream.length, stream.buffer!, stream.position);
      }
    } else {
      final bytes = stream.toUint8List();
      _buffer.setRange(length, length + stream.length, bytes, 0);
    }
    length += stream.length;
  }

  /// Return the subset of the buffer in the range [start:end].
  ///
  /// If [start] or [end] are < 0 then it is relative to the end of the buffer.
  /// If [end] is not specified (or null), then it is the end of the buffer.
  /// This is equivalent to the python list range operator.
  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) {
      start = length + start;
    }

    if (end == null) {
      end = length;
    } else if (end < 0) {
      end = length + end;
    }

    return Uint8List.view(
        _buffer.buffer, _buffer.offsetInBytes + start, end - start);
  }

  /// Grow the buffer to accommodate additional data.
  void _expandBuffer([int? required]) {
    var blockSize = defaultBufferSize;
    if (required != null) {
      if (required > defaultBufferSize) {
        blockSize = required;
      }
    }
    final newLength = (_buffer.length + blockSize) * 2;
    final newBuffer = Uint8List(newLength)
      ..setRange(0, _buffer.length, _buffer);
    _buffer = newBuffer;
  }
}

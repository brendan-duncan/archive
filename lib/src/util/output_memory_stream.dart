import 'dart:typed_data';

import 'byte_order.dart';
import 'input_decode_stream.dart';
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

  /// Grows the buffer to hold [total] bytes without another copy. A caller that
  /// knows the size up front saves every doubling it would have taken
  @override
  void reserve(int total) {
    if (total > _buffer.length) {
      _buffer = Uint8List(total)..setRange(0, length, _buffer);
    }
  }

  /// Clear the buffer.
  @override
  void clear() {
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
    if (stream is InputMemoryStream) {
      // An in-memory stream already provides direct access to its data.
      final count = stream.length;
      while (length + count > _buffer.length) {
        _expandBuffer(length + count - _buffer.length);
      }
      if (stream.buffer != null) {
        _buffer.setRange(
            length, length + count, stream.buffer!, stream.position);
      }
      length += count;
      return;
    }

    // Advancing a decode view discards data at the source's original position.
    if (stream is InputDecodeStream) {
      writeBytes(stream.toUint8List());
      return;
    }

    // Copy bounded pieces through a view, leaving the source position intact.
    final reader = stream.subset(position: stream.position);
    final scratch = Uint8List(64 * 1024);
    while (!reader.isEOS) {
      final got = reader.readInto(scratch, 0, scratch.length);
      if (got <= 0) {
        break;
      }
      writeBytes(scratch, length: got);
    }
  }

  @override
  void writeBackReference(int distance, int count) {
    while (length + count > _buffer.length) {
      _expandBuffer((length + count) - _buffer.length);
    }
    final src = length - distance;
    if (distance >= count) {
      // Non-overlapping copy: bulk move is safe and fast.
      _buffer.setRange(length, length + count, _buffer, src);
    } else {
      // Overlapping copy (LZ77 run): copy forward byte-by-byte so the source
      // bytes written earlier in this same call are repeated correctly.
      var s = src;
      var d = length;
      final end = length + count;
      while (d < end) {
        _buffer[d++] = _buffer[s++];
      }
    }
    length += count;
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
  ///
  /// [required] is the number of bytes needed beyond the current buffer
  /// capacity (the deficit). The buffer grows geometrically (doubling) to keep
  /// amortized append cost O(1), but is always grown by at least [required] so
  /// a single call satisfies the request.
  void _expandBuffer([int? required]) {
    final minLength = _buffer.length + (required ?? 1);
    var newLength = _buffer.isEmpty ? defaultBufferSize : _buffer.length * 2;
    if (newLength < minLength) {
      newLength = minLength;
    }
    // The unwritten tail of the previous allocation is not data. Copying
    // the entire capacity can move hundreds of megabytes of unused bytes.
    final newBuffer = Uint8List(newLength)..setRange(0, length, _buffer);
    _buffer = newBuffer;
  }
}

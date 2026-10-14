//import 'dart:async';
import 'dart:typed_data';

import 'byte_order.dart';
import 'input_stream.dart';

abstract class OutputStream {
  ByteOrder byteOrder;

  int get length;

  OutputStream({required this.byteOrder});

  void open() {}

  Future<void> close() async {}

  void closeSync() {}

  bool get isOpen => true;

  void clear();

  /// Write any pending data writes to the output.
  void flush();

  /// Write a byte to the output stream.
  void writeByte(int value);

  /// Write a set of bytes to the output stream.
  void writeBytes(List<int> bytes, {int? length});

  /// Writes `bytes[start...end]`. A sink that passes its data to something
  /// outside Dart takes the range rather than a view of it, since a view is
  /// copied on the way out
  void writeRange(Uint8List bytes, int start, int end) {
    writeBytes(Uint8List.sublistView(bytes, start, end));
  }

  /// Tells a sink that holds its data the size it will reach, so it can take
  /// the room in one go rather than doubling into it. A sink that writes
  /// through has nothing to reserve and ignores it
  void reserve(int total) {}

  /// Write an InputStream to the output stream.
  ///
  /// Writes [stream] from its current position to its end and leaves that
  /// position unchanged, so [stream] can be written again
  void writeStream(InputStream stream);

  /// Write a 16-bit word to the output stream.
  void writeUint16(int value) {
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte((value >> 8) & 0xff);
      writeByte(value & 0xff);
    } else {
      writeByte(value & 0xff);
      writeByte((value >> 8) & 0xff);
    }
  }

  /// Write a 32-bit word to the end of the buffer.
  void writeUint32(int value) {
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte(value & 0xff);
    } else {
      writeByte(value & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 24) & 0xff);
    }
  }

  /// Write a 64-bit word to the end of the buffer.
  void writeUint64(int value) {
    // Works around Dart treating 64 bit integers as signed when shifting.
    var topBit = 0x00;
    if (value & 0x8000000000000000 != 0) {
      topBit = 0x80;
      value ^= 0x8000000000000000;
    }
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte(topBit | ((value >> 56) & 0xff));
      writeByte((value >> 48) & 0xff);
      writeByte((value >> 40) & 0xff);
      writeByte((value >> 32) & 0xff);
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
    writeByte((value >> 32) & 0xff);
    writeByte((value >> 40) & 0xff);
    writeByte((value >> 48) & 0xff);
    writeByte(topBit | ((value >> 56) & 0xff));
  }

  Uint8List subset(int start, [int? end]);

  /// Append [count] bytes copied from [distance] bytes before the current end
  /// of the stream (an LZ77 back-reference, as used by [Inflate]). Correctly
  /// handles overlapping copies where [count] > [distance] (e.g. RLE-style
  /// runs), reproducing the repeating pattern.
  ///
  /// This default implementation is expressed in terms of [subset] and
  /// [writeBytes]; subclasses backed by a contiguous buffer should override it
  /// with a direct in-buffer copy to avoid per-iteration view allocations.
  void writeBackReference(int distance, int count) {
    while (count > distance) {
      writeBytes(subset(-distance));
      count -= distance;
    }
    if (count == distance) {
      writeBytes(subset(-distance));
    } else {
      writeBytes(subset(-distance, count - distance));
    }
  }

  Uint8List getBytes() => subset(0, length);
}

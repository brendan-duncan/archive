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

  /// Write an InputStream to the output stream.
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

  Uint8List getBytes() => subset(0, length);
}

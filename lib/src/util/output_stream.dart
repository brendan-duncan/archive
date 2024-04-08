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
  void writeBytes(Uint8List bytes, {int? length});

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

  Uint8List subset(int start, {int? end});

  Uint8List getBytes() => subset(0, end: length);
}

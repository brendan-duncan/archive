import 'dart:async';
import 'dart:typed_data';

import 'byte_order.dart';
import 'input_stream.dart';

abstract class OutputStream {
  ByteOrder byteOrder;

  int get length;

  OutputStream({required this.byteOrder});

  FutureOr<void> open() async {}

  FutureOr<void> close() async {}

  bool get isOpen => true;

  FutureOr<void> clear();

  /// Write any pending data writes to the output.
  FutureOr<void> flush();

  /// Write a byte to the output stream.
  FutureOr<void> writeByte(int value);

  /// Write a set of bytes to the output stream.
  FutureOr<void> writeBytes(Uint8List bytes, {int? length});

  /// Write an InputStream to the output stream.
  FutureOr<void> writeStream(InputStream stream);

  /// Write a 16-bit word to the output stream.
  Future<void> writeUint16(int value) async {
    if (byteOrder == ByteOrder.bigEndian) {
      await writeByte((value >> 8) & 0xff);
      await writeByte(value & 0xff);
    } else {
      await writeByte(value & 0xff);
      await writeByte((value >> 8) & 0xff);
    }
  }

  /// Write a 32-bit word to the end of the buffer.
  Future<void> writeUint32(int value) async {
    if (byteOrder == ByteOrder.bigEndian) {
      await writeByte((value >> 24) & 0xff);
      await writeByte((value >> 16) & 0xff);
      await writeByte((value >> 8) & 0xff);
      await writeByte(value & 0xff);
    } else {
      await writeByte(value & 0xff);
      await writeByte((value >> 8) & 0xff);
      await writeByte((value >> 16) & 0xff);
      await writeByte((value >> 24) & 0xff);
    }
  }

  FutureOr<Uint8List> subset(int start, {int? end});

  FutureOr<Uint8List> getBytes() async => subset(0, end: length);
}

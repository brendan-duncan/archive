//import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'byte_order.dart';

abstract class InputStream {
  /// The current endian order if the stream.
  ByteOrder byteOrder;

  /// The current read position relative to the start of the buffer.
  int get position;

  /// Set the current read position relative to the start of the buffer.
  set position(int v);

  /// How many bytes are left in the stream.
  int get length;

  /// Is the current position at the end of the stream?
  bool get isEOS;

  InputStream({required this.byteOrder});

  bool open();

  /// Asynchronously closes the input stream.
  Future<void> close();

  /// Synchronously closes the input stream.
  void closeSync();

  /// Reset to the beginning of the stream.
  void reset();

  void setPosition(int v);

  /// Rewind the read head of the stream by the given number of bytes.
  void rewind([int length = 1]);

  /// Move the read position by [length] bytes.
  void skip(int length);

  /// Read [count] bytes from an [offset] of the current read position, without
  /// moving the read position.
  InputStream peekBytes(int count, {int offset = 0}) =>
      subset(position: position + offset, length: count);

  /// Return a [InputStream] to read a subset of this stream. It does not
  /// move the read position of this stream. [position] is specified relative
  /// to the start of the buffer. If [position] is not specified, the current
  /// read position is used. If [length] is not specified, the remainder of this
  /// stream is used.
  /// If [bufferSize] is provided, and this is an [InputFileStream], the
  /// returned [InputStream] will get its own [FileBuffer] with the given
  /// [bufferSize], otherwise it will share the [FileBuffer] of this
  /// [InputFileStream].
  InputStream subset({int? position, int? length, int? bufferSize});

  /// Read a single byte.
  int readByte();

  /// Read a single byte.
  int readUint8() => readByte();

  /// Read a 16-bit word from the stream.
  int readUint16() {
    final b1 = readByte();
    final b2 = readByte();
    if (byteOrder == ByteOrder.bigEndian) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  /// Read a 24-bit word from the stream.
  int readUint24() {
    final b1 = readByte();
    final b2 = readByte();
    final b3 = readByte();
    if (byteOrder == ByteOrder.bigEndian) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  /// Read a 32-bit word from the stream.
  int readUint32() {
    final b1 = readByte();
    final b2 = readByte();
    final b3 = readByte();
    final b4 = readByte();
    if (byteOrder == ByteOrder.bigEndian) {
      return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /// Read a 64-bit word form the stream.
  int readUint64() {
    final b1 = readByte();
    final b2 = readByte();
    final b3 = readByte();
    final b4 = readByte();
    final b5 = readByte();
    final b6 = readByte();
    final b7 = readByte();
    final b8 = readByte();
    if (byteOrder == ByteOrder.bigEndian) {
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

  /// Read [count] bytes from the stream.
  InputStream readBytes(int count) {
    final bytes = subset(position: position, length: count);
    setPosition(position + bytes.length);
    return bytes;
  }

  /// Read a null-terminated string, or if [size] is provided, that number of
  /// bytes returned as a string.
  String readString({int? size, bool utf8 = true}) {
    String codesToString(List<int> codes) {
      try {
        final str = utf8
            ? const Utf8Decoder().convert(codes)
            : String.fromCharCodes(codes);
        return str;
      } catch (err) {
        // If the string is not a valid UTF8 string, decode it as character
        // codes.
        return String.fromCharCodes(codes);
      }
    }

    if (size == null) {
      final codes = <int>[];
      if (isEOS) {
        return '';
      }
      while (!isEOS) {
        final c = readByte();
        if (c == 0) {
          return codesToString(codes);
        }
        codes.add(c);
      }
      return codesToString(codes);
    }

    final s = readBytes(size);
    final codes = s.toUint8List();
    return codesToString(codes);
  }

  /// Convert the remaining bytes to a Uint8List.
  Uint8List toUint8List();
}

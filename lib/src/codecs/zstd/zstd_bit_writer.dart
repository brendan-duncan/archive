import 'dart:typed_data';

import 'zstd_bit_reader.dart';

/// Writes a little endian bitstream into a buffer, lowest bits first, for the
/// Huffman and FSE streams the encoder produces.
///
/// zstd reads its entropy streams backwards, so whatever is written last is
/// read first. [closeBackward] adds the end marker those streams need.
///
/// Where ints are 64 bits wide the container holds up to 63 bits and is
/// flushed 32 at a time. On JavaScript it stays below 30 bits, which numbers
/// that size can hold without an allocation, and is flushed a byte at a time.
class ZstdBitWriter {
  Uint8List _buf = Uint8List(0);
  ByteData _data = ByteData(0);
  int _pos = 0;
  int _bits = 0;
  int _count = 0;

  /// Starts writing into [buf] at [pos].
  void reset(Uint8List buf, int pos) {
    if (!identical(buf, _buf)) {
      _buf = buf;
      _data = ByteData.sublistView(buf);
    }
    _pos = pos;
    _bits = 0;
    _count = 0;
  }

  /// Adds the low [n] bits of [value], at most 32 of them. [value] must have
  /// no bits set above those.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  void addBits(int value, int n) {
    if (ZstdBitReader.has64BitInts) {
      _bits |= value << _count;
      _count += n;
      if (_count >= 32) {
        _data.setUint32(_pos, _bits & 0xffffffff, Endian.little);
        _pos += 4;
        _bits >>>= 32;
        _count -= 32;
      }
    } else {
      if (n > 22) {
        _addSmall(value & 0xffff, 16);
        _addSmall(value >>> 16, n - 16);
      } else {
        _addSmall(value, n);
      }
    }
  }

  @pragma('dart2js:prefer-inline')
  void _addSmall(int value, int n) {
    _bits |= value << _count;
    _count += n;
    while (_count >= 8) {
      _buf[_pos++] = _bits & 0xff;
      _bits >>>= 8;
      _count -= 8;
    }
  }

  void _flushBytes() {
    while (_count > 0) {
      _buf[_pos++] = _bits & 0xff;
      _bits >>>= 8;
      _count -= 8;
    }
    _bits = 0;
    _count = 0;
  }

  /// Ends a forward stream, padding its last byte with zeros, and returns the
  /// position after it.
  int closeForward() {
    _flushBytes();
    return _pos;
  }

  /// Ends a stream that will be read backwards, with the end marker it needs,
  /// and returns the position after it.
  int closeBackward() {
    addBits(1, 1);
    _flushBytes();
    return _pos;
  }
}

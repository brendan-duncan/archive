import 'dart:typed_data';

// The backward bit reader for JavaScript targets, where bitwise operators work
// on 32 bits. See zstd_bit_reader.dart for why there are two.
//
// The container holds at most 30 bits. JavaScript engines store a number
// that large as it is, but one any larger as a separate allocation, every time
// it is assigned. Every value is masked explicitly, so that this reader behaves
// the same on the VM and can be tested there.

/// Reads a zstd backward bitstream, using a 32 bit container.
class ZstdBitReader {
  /// Whether ints are 64 bits wide here, which decides how other platform
  /// sensitive code in the decoder is written as well.
  static const bool has64BitInts = false;

  /// The largest count [readBits] accepts.
  static const int maxReadBits = 32;

  /// How many bits [refill] guarantees can be peeked without another refill.
  static const int bitsAfterRefill = 23;

  Uint8List _buf = Uint8List(0);
  int _start = 0;
  // The next byte to load is the one before this.
  int _pos = 0;
  int _bits = 0;
  // How many of the low bits of [_bits] are still unread, counting padding.
  int _count = 0;
  // How many zero bits were appended once the stream ran out. Reading into
  // them is what marks a stream as overread.
  int _pad = 0;

  /// Starts reading the stream in [buf] from [start] to [end].
  ///
  /// Returns false if the stream is empty or its last byte, which must hold
  /// the end marker, is zero.
  bool init(Uint8List buf, int start, int end) {
    if (end <= start) {
      return false;
    }
    final last = buf[end - 1];
    if (last == 0) {
      return false;
    }
    _buf = buf;
    _start = start;
    _pos = end - 1;
    _bits = last;
    // Everything below the marker is data.
    _count = last.bitLength - 1;
    _pad = 0;
    return true;
  }

  /// Whether every bit of the stream has been read, and no more.
  bool get isFinished => _pos == _start && _count == _pad;

  /// Whether more bits were read than the stream holds.
  bool get isOverflowed => _count < _pad;

  void _refill() {
    var bits = _bits;
    var count = _count;
    var pos = _pos;
    final buf = _buf;
    while (count <= 22) {
      if (pos > _start) {
        bits = ((bits << 8) | buf[--pos]) & 0x3fffffff;
      } else {
        bits = (bits << 8) & 0x3fffffff;
        _pad += 8;
      }
      count += 8;
    }
    _bits = bits;
    _count = count;
    _pos = pos;
  }

  /// Makes sure at least 23 bits can be read or peeked without a refill.
  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  void refill() {
    if (_count <= 22) {
      _refill();
    }
  }

  /// Reads [n] bits, at most [maxReadBits].
  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  int readBits(int n) {
    if (n > 22) {
      // More than a refill guarantees. Only offsets are this wide.
      final high = _readBits(n - 16);
      return high * 0x10000 + _readBits(16);
    }
    return _readBits(n);
  }

  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  int _readBits(int n) {
    if (_count < n) {
      _refill();
    }
    final c = _count - n;
    _count = c;
    return (_bits >>> c) & ((1 << n) - 1);
  }

  /// Returns the next [n] bits, at most 22, without consuming them.
  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  int peekBits(int n) {
    if (_count < n) {
      _refill();
    }
    return (_bits >>> (_count - n)) & ((1 << n) - 1);
  }

  /// Peeks [n] bits when a [refill] has already guaranteed that they are
  /// there.
  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  int peekBitsFast(int n) => (_bits >>> (_count - n)) & ((1 << n) - 1);

  /// Consumes [n] bits previously peeked.
  @pragma('dart2js:prefer-inline')
  @pragma('vm:prefer-inline')
  void skipBits(int n) {
    _count -= n;
  }
}

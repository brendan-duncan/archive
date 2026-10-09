import 'dart:typed_data';

// The backward bit reader for backends where an int is a real 64 bit integer,
// the VM and wasm. See zstd_bit_reader.dart for why there are two.
//
// A zstd bitstream is written forwards and read backwards: the last byte holds
// an end marker, its highest set bit, and reading starts with the bits just
// below it, working towards the first byte. The container is always the eight
// bytes starting at [_ptr], read as one little endian number, so the next bits
// to come out are its highest unconsumed ones. Refilling moves [_ptr] back by
// however many whole bytes have been consumed and reloads all eight in one go.

/// Reads a zstd backward bitstream, using a 64 bit container.
class ZstdBitReader {
  /// Whether ints are 64 bits wide here, which decides how other platform
  /// sensitive code in the decoder is written as well.
  static const bool has64BitInts = true;

  /// The largest count [readBits] accepts.
  static const int maxReadBits = 32;

  /// How many bits [refill] guarantees can be peeked without another refill,
  /// until the stream runs out.
  static const int bitsAfterRefill = 57;

  Uint8List _buf = Uint8List(0);
  ByteData _data = ByteData(0);
  int _start = 0;
  int _ptr = 0;
  int _container = 0;
  // How many of the container's bits, counting from the top, have been read.
  int _consumed = 0;
  // How many of the container's bits are the stream's, once [_ptr] reaches
  // the start: all 64 unless the stream is shorter than that. Reading past
  // this reads beyond the start of the stream.
  int _limit = 64;

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
    if (!identical(buf, _buf)) {
      _buf = buf;
      _data = ByteData.sublistView(buf);
    }
    _start = start;
    // The marker and the zero bits above it are consumed from the outset.
    final skip = 9 - last.bitLength;
    if (end - start >= 8) {
      _ptr = end - 8;
      _container = _data.getUint64(_ptr, Endian.little);
      _limit = 64;
    } else {
      // Too short for a full load. The bytes there are go at the top of the
      // container, with zeros below them where the reads run past the start.
      var c = 0;
      for (var i = start; i < end; i++) {
        c |= buf[i] << ((i - start) * 8);
      }
      final missing = 8 - (end - start);
      _ptr = start;
      _container = c << (missing * 8);
      _limit = 64 - missing * 8;
    }
    _consumed = skip;
    return true;
  }

  /// Whether every bit of the stream has been read, and no more.
  bool get isFinished => _ptr == _start && _consumed == _limit;

  /// Whether more bits were read than the stream holds.
  bool get isOverflowed => _consumed > _limit;

  void _reload() {
    final consumed = _consumed;
    var back = consumed >> 3;
    if (back > _ptr - _start) {
      // Near the start, where only what is left can be loaded. Once it is all
      // loaded, reads past the start come out as zeros.
      back = _ptr - _start;
      if (back == 0) {
        return;
      }
    }
    _ptr -= back;
    _consumed = consumed - back * 8;
    _container = _data.getUint64(_ptr, Endian.little);
  }

  /// Makes sure at least 57 bits can be read or peeked without a refill,
  /// unless the stream has fewer than that left.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void refill() {
    if (_consumed > 7) {
      _reload();
    }
  }

  /// Reads [n] bits, at most [maxReadBits].
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int readBits(int n) {
    if (_consumed + n > 64) {
      _reload();
    }
    final c = _consumed;
    _consumed = c + n;
    return (_container << c) >>> (64 - n);
  }

  /// Returns the next [n] bits, at most 22, without consuming them.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int peekBits(int n) {
    if (_consumed + n > 64) {
      _reload();
    }
    return (_container << _consumed) >>> (64 - n);
  }

  /// Peeks [n] bits when a [refill] has already guaranteed that they are
  /// there.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int peekBitsFast(int n) => (_container << _consumed) >>> (64 - n);

  /// Consumes [n] bits previously peeked.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void skipBits(int n) {
    _consumed += n;
  }
}

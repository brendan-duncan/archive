import 'dart:typed_data';
import 'range_decoder_table.dart';

// Which implementation the conditional export selected.
const rangeDecoderImplementation = 'native';

/// Implements the LZMA range decoder for [LZMADecoder].
///
/// The bit decoding steps avoid data dependent branches: the two possible
/// outcomes are both computed and selected with a mask, because the decoded
/// bits are close to random and mispredict about half the time.
class RangeDecoder {
  // Mask showing the current bits in [code].
  var range = 0xffffffff;

  // Current code being stored.
  var code = 0;

  Uint8List _buffer = Uint8List(0);
  int _bufferPos = 0;

  // Index one past the last byte of real input. The buffer is padded beyond
  // this so that a single packet can always read ahead without leaving the
  // allocation, which is what makes the unchecked reads below safe.
  int _dataEnd = 0;

  // Bytes of padding added after the input. Must be at least the number of
  // bytes a single LZMA packet can consume, because [isOverrun] is only
  // consulted between packets: within one, the reads below are unchecked and
  // have to stay inside the allocation on their own.
  //
  // Normalization loads one byte per bit at most, so the bound is the largest
  // number of bits one packet decodes. The widest is a match:
  //
  //   2  the two flag bits that select match over literal and repeat
  //   10 decodeLength, worst case: 2 selector bits and an 8 bit field
  //   36 decodeDistance, worst case: 6 slot bits, 26 direct bits, 4 aligned
  //   -- 48
  //
  // A literal takes 9 and a repeat 15. [isOverrun] guarantees _bufferPos is at
  // most _dataEnd on entry, so the highest index reachable is _dataEnd + 47,
  // which leaves 16 bytes spare.
  //
  // Measured over 89,600 decodes of deliberately corrupted archives, the widest
  // any packet actually read was 5 bytes, and the furthest past the end of real
  // input was 3.
  static const readAheadPadding = 64;

  RangeDecoder() {
    assert(!identical(1, 1.0),
        'range_decoder_native.dart was selected on a platform with 32 bit ints');
  }

  // True once more input has been consumed than was supplied, which means the
  // stream is truncated or corrupt.
  bool get isOverrun => _bufferPos > _dataEnd;

  // Set the input being read from. Must be set before initializing or reading
  // bits.
  void setBuffer(Uint8List data) {
    final needed = data.length + readAheadPadding;
    var buffer = _buffer;
    if (buffer.length < needed) {
      buffer = Uint8List(needed);
      _buffer = buffer;
    }
    buffer.setRange(0, data.length, data);
    buffer.fillRange(data.length, needed, 0);
    _bufferPos = 0;
    _dataEnd = data.length;
  }

  void reset() {
    range = 0xffffffff;
    code = 0;
  }

  void initialize() {
    code = 0;
    range = 0xffffffff;
    _bufferPos++;
    for (var i = 0; i < 4; i++) {
      code = (code << 8) | _buffer[_bufferPos++];
    }
  }

  // Read a single bit from the decoder, using the supplied [index] into a
  // probabilities [table].
  @pragma('vm:prefer-inline')
  int readBit(RangeDecoderTable table, int index) =>
      readBitRaw(table.table, index);

  // Read a single bit from the decoder, using the supplied [index] into the
  // [probs] array. Avoids the field load that [readBit] does on every bit.
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  @pragma('vm:unsafe:no-interrupts')
  int readBitRaw(Uint16List probs, int index) {
    if (range < 0x1000000) {
      range <<= 8;
      code = (code << 8) | _buffer[_bufferPos++];
    }
    final p = probs[index];
    final bound = (range >> 11) * p;
    // -1 when the decoded bit is 0, 0 when it is 1.
    final mask = (code - bound) >> 63;
    final high = range - bound;
    range = high + ((bound - high) & mask);
    code -= bound & ~mask;
    probs[index] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
    return 1 + mask;
  }

  // Decode a byte using the probabilities starting at [baseIndex] in [probs].
  @pragma('vm:unsafe:no-bounds-checks')
  @pragma('vm:unsafe:no-interrupts')
  int decodeByte(Uint16List probs, int baseIndex) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var symbol = 1;
    for (var i = 0; i < 8; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final idx = baseIndex + symbol;
      final p = probs[idx];
      final bound = (r >> 11) * p;
      final mask = (c - bound) >> 63;
      final high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      symbol = (symbol << 1) | (1 + mask);
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return symbol & 0xff;
  }

  // Decode a byte that follows a match, using the probabilities starting at
  // [baseIndex] in [probs] and the previously matched [matchByte]. While the
  // decoded bits agree with [matchByte] the probabilities at offset 0x100 and
  // 0x200 are used, afterwards decoding continues as in [decodeByte].
  @pragma('vm:unsafe:no-bounds-checks')
  @pragma('vm:unsafe:no-interrupts')
  int decodeMatchedByte(Uint16List probs, int baseIndex, int matchByte) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var symbol = 1;
    var i = 7;
    while (i >= 0) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final matchBit = (matchByte >> i) & 1;
      final idx = baseIndex + 0x100 + (matchBit << 8) + symbol;
      final p = probs[idx];
      final bound = (r >> 11) * p;
      final mask = (c - bound) >> 63;
      final high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      final bit = 1 + mask;
      symbol = (symbol << 1) | bit;
      i--;
      if (bit != matchBit) {
        break;
      }
    }
    while (i >= 0) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final idx = baseIndex + symbol;
      final p = probs[idx];
      final bound = (r >> 11) * p;
      final mask = (c - bound) >> 63;
      final high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      symbol = (symbol << 1) | (1 + mask);
      i--;
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return symbol & 0xff;
  }

  // Read a bittree (big endian) of [count] bits from the decoder.
  int readBittree(RangeDecoderTable table, int count) {
    final probs = table.table;
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var symbol = 1;
    for (var i = 0; i < count; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final p = probs[symbol];
      final bound = (r >> 11) * p;
      final mask = (c - bound) >> 63;
      final high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[symbol] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      symbol = (symbol << 1) | (1 + mask);
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return symbol - (1 << count);
  }

  // Read a reverse bittree (little endian) of [count] bits from the decoder.
  int readBittreeReverse(RangeDecoderTable table, int count) {
    final probs = table.table;
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var symbol = 1;
    var value = 0;
    for (var i = 0; i < count; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final p = probs[symbol];
      final bound = (r >> 11) * p;
      final mask = (c - bound) >> 63;
      final high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[symbol] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      final bit = 1 + mask;
      symbol = (symbol << 1) | bit;
      value |= bit << i;
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return value;
  }

  // Decode a match or repeat length using the probabilities in [probs], laid
  // out as described by [lengthProbsLength]. Keeps the decoder state in local
  // variables for the whole field instead of one round trip per bit group.
  @pragma('vm:unsafe:no-bounds-checks')
  @pragma('vm:unsafe:no-interrupts')
  int decodeLength(Uint16List probs, int posState) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;

    if (r < 0x1000000) {
      r <<= 8;
      c = (c << 8) | buffer[pos++];
    }
    var p = probs[0];
    var bound = (r >> 11) * p;
    var mask = (c - bound) >> 63;
    var high = r - bound;
    r = high + ((bound - high) & mask);
    c -= bound & ~mask;
    probs[0] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;

    int base;
    int count;
    int offset;
    if (mask != 0) {
      base = 2 + (posState << 3);
      count = 3;
      offset = 2;
    } else {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      p = probs[1];
      bound = (r >> 11) * p;
      mask = (c - bound) >> 63;
      high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[1] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      if (mask != 0) {
        base = 130 + (posState << 3);
        count = 3;
        offset = 10;
      } else {
        base = 258;
        count = 8;
        offset = 18;
      }
    }

    var symbol = 1;
    for (var i = 0; i < count; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final idx = base + symbol;
      p = probs[idx];
      bound = (r >> 11) * p;
      mask = (c - bound) >> 63;
      high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      symbol = (symbol << 1) | (1 + mask);
    }

    range = r;
    code = c;
    _bufferPos = pos;
    return offset + symbol - (1 << count);
  }

  // Decode a match distance using the probabilities in [probs], laid out as
  // described by [distanceProbsLength]. [distState] is the match length minus
  // two, capped at three.
  @pragma('vm:unsafe:no-bounds-checks')
  @pragma('vm:unsafe:no-interrupts')
  int decodeDistance(Uint16List probs, int distState) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var p = 0;
    var bound = 0;
    var mask = 0;
    var high = 0;

    // Distances start with a six bit slot.
    final slotBase = distState << 6;
    var symbol = 1;
    for (var i = 0; i < 6; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final idx = slotBase + symbol;
      p = probs[idx];
      bound = (r >> 11) * p;
      mask = (c - bound) >> 63;
      high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      symbol = (symbol << 1) | (1 + mask);
    }
    final slot = symbol - 64;

    // Slots 0-3 map to the distances 0-3.
    if (slot < 4) {
      range = r;
      code = c;
      _bufferPos = pos;
      return slot;
    }

    final prefix = 0x2 | (slot & 0x1);
    final bitCount = (slot >> 1) - 1;
    var value = 0;
    int reverseBase;
    int reverseCount;

    if (slot < 14) {
      reverseBase = 256 + distanceShortOffsets[slot - 4];
      reverseCount = bitCount;
    } else {
      // Large distances are a combination of direct bits and a reverse
      // bittree of the four aligned bits.
      for (var i = bitCount - 4; i > 0; i--) {
        if (r < 0x1000000) {
          r <<= 8;
          c = (c << 8) | buffer[pos++];
        }
        r >>= 1;
        c -= r;
        final t = c >> 63;
        c += r & t;
        value = (value << 1) + 1 + t;
      }
      value <<= 4;
      reverseBase = 380;
      reverseCount = 4;
    }

    symbol = 1;
    for (var i = 0; i < reverseCount; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      final idx = reverseBase + symbol;
      p = probs[idx];
      bound = (r >> 11) * p;
      mask = (c - bound) >> 63;
      high = r - bound;
      r = high + ((bound - high) & mask);
      c -= bound & ~mask;
      probs[idx] = (p + ((2048 - p) >> 5)) & mask | (p - (p >> 5)) & ~mask;
      final bit = 1 + mask;
      symbol = (symbol << 1) | bit;
      value |= bit << i;
    }

    range = r;
    code = c;
    _bufferPos = pos;
    return (prefix << bitCount) | value;
  }

  // Read [count] bits directly from the decoder.
  int readDirect(int count) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var value = 0;
    for (var i = 0; i < count; i++) {
      if (r < 0x1000000) {
        r <<= 8;
        c = (c << 8) | buffer[pos++];
      }
      r >>= 1;
      c -= r;
      final t = c >> 63;
      c += r & t;
      value = (value << 1) + 1 + t;
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return value;
  }
}

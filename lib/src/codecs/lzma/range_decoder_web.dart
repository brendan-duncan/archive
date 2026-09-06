import 'dart:typed_data';

import 'range_decoder_table.dart';

// Which implementation the conditional export selected.
const rangeDecoderImplementation = 'web';

/// Implements the LZMA range decoder for [LZMADecoder] on web targets.
///
/// On the web an int is a JavaScript number and the bitwise operators work on
/// 32 bits, so the branchless masks used by the native implementation cannot be
/// expressed. Every intermediate value here stays below 2^32 and the two
/// possible outcomes are selected with a branch, which is what a JavaScript
/// engine wants anyway.
class RangeDecoder {
  // Mask showing the current bits in [code].
  var range = 0xffffffff;

  // Current code being stored.
  var code = 0;

  Uint8List _buffer = Uint8List(0);
  int _bufferPos = 0;

  // Index one past the last byte of real input. The buffer is padded beyond
  // this so that a single packet can always read ahead without leaving the
  // allocation.
  int _dataEnd = 0;

  // Bytes of padding added after the input. Must be at least the number of
  // bytes a single LZMA packet can consume, since [isOverrun] is only consulted
  // between packets. See range_decoder_native.dart for how the bound of 48 is
  // arrived at; the two implementations decode the same packets.
  static const readAheadPadding = 64;

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
  @pragma('dart2js:prefer-inline')
  int readBit(RangeDecoderTable table, int index) =>
      readBitRaw(table.table, index);

  // Read a single bit from the decoder, using the supplied [index] into the
  // [probs] array. Avoids the field load that [readBit] does on every bit.
  @pragma('dart2js:prefer-inline')
  int readBitRaw(Uint16List probs, int index) {
    if (range < 0x1000000) {
      range <<= 8;
      code = (code << 8) | _buffer[_bufferPos++];
    }
    final p = probs[index];
    final bound = (range >> 11) * p;
    if (code < bound) {
      range = bound;
      probs[index] = p + ((2048 - p) >> 5);
      return 0;
    }
    range -= bound;
    code -= bound;
    probs[index] = p - (p >> 5);
    return 1;
  }

  // Decode a byte using the probabilities starting at [baseIndex] in [probs].
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
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        symbol = symbol << 1;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        symbol = (symbol << 1) | 1;
      }
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
      final int bit;
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        bit = 0;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        bit = 1;
      }
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
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        symbol = symbol << 1;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        symbol = (symbol << 1) | 1;
      }
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
      if (c < bound) {
        r = bound;
        probs[symbol] = p + ((2048 - p) >> 5);
        symbol = symbol << 1;
      } else {
        r -= bound;
        c -= bound;
        probs[symbol] = p - (p >> 5);
        symbol = (symbol << 1) | 1;
      }
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
      final int bit;
      if (c < bound) {
        r = bound;
        probs[symbol] = p + ((2048 - p) >> 5);
        bit = 0;
      } else {
        r -= bound;
        c -= bound;
        probs[symbol] = p - (p >> 5);
        bit = 1;
      }
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
    int bit;
    if (c < bound) {
      r = bound;
      probs[0] = p + ((2048 - p) >> 5);
      bit = 0;
    } else {
      r -= bound;
      c -= bound;
      probs[0] = p - (p >> 5);
      bit = 1;
    }

    int base;
    int count;
    int offset;
    if (bit == 0) {
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
      if (c < bound) {
        r = bound;
        probs[1] = p + ((2048 - p) >> 5);
        bit = 0;
      } else {
        r -= bound;
        c -= bound;
        probs[1] = p - (p >> 5);
        bit = 1;
      }
      if (bit == 0) {
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
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        symbol = symbol << 1;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        symbol = (symbol << 1) | 1;
      }
    }

    range = r;
    code = c;
    _bufferPos = pos;
    return offset + symbol - (1 << count);
  }

  // Decode a match distance using the probabilities in [probs], laid out as
  // described by [distanceProbsLength]. [distState] is the match length minus
  // two, capped at three.
  int decodeDistance(Uint16List probs, int distState) {
    final buffer = _buffer;
    var pos = _bufferPos;
    var r = range;
    var c = code;
    var p = 0;
    var bound = 0;

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
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        symbol = symbol << 1;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        symbol = (symbol << 1) | 1;
      }
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
        if (c < r) {
          value = value << 1;
        } else {
          c -= r;
          value = (value << 1) + 1;
        }
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
      final int bit;
      if (c < bound) {
        r = bound;
        probs[idx] = p + ((2048 - p) >> 5);
        bit = 0;
      } else {
        r -= bound;
        c -= bound;
        probs[idx] = p - (p >> 5);
        bit = 1;
      }
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
      if (c < r) {
        value = value << 1;
      } else {
        c -= r;
        value = (value << 1) + 1;
      }
    }
    range = r;
    code = c;
    _bufferPos = pos;
    return value;
  }
}

import 'dart:typed_data';

import '../../util/input_stream.dart';

// Number of bits used for probabilities.
const _probabilityBitCount = 11;

// Value used for a probability of 1.0.
const _probabilityOne = (1 << _probabilityBitCount);

// Value used for a probability of 0.5.
const _probabilityHalf = _probabilityOne ~/ 2;

/// Probability table used with [RangeDecoder].
class RangeDecoderTable {
  // Table of probabilities for each symbol.
  final Uint16List table;

  // Creates a new probability table for [length] elements.
  RangeDecoderTable(int length) : table = Uint16List(length) {
    reset();
  }

  // Reset the table to probabilities of 0.5.
  void reset() {
    table.fillRange(0, table.length, _probabilityHalf);
  }
}

/// Implements the LZMA range decoder for [LZMADecoder].
class RangeDecoder {
  // Data being read from.
  late InputStream _input;

  // Mask showing the current bits in [code].
  var range = 0xffffffff;

  // Current code being stored.
  var code = 0;

  Uint8List _buffer = Uint8List(0);
  int _bufferPos = 0;

  // Set the input being read from. Must be set before initializing or reading
  // bits.
  void setBuffer(Uint8List data) {
    _buffer = data;
    _bufferPos = 0;
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
  int readBit(RangeDecoderTable table, int index) {
    if (range < 0x1000000) {
      range <<= 8;
      code = (code << 8) | _buffer[_bufferPos++];
    }
    final p = table.table[index];
    final bound = (range >> 11) * p;
    if (code < bound) {
      range = bound;
      table.table[index] += (2048 - p) >> 5;
      return 0;
    } else {
      range -= bound;
      code -= bound;
      table.table[index] -= p >> 5;
      return 1;
    }
  }

  int decodeByte(Uint16List probs, int baseIndex) {
    var symbol = 1;
    for (var i = 0; i < 8; i++) {
      if (range < 0x1000000) {
        range <<= 8;
        code = (code << 8) | _buffer[_bufferPos++];
      }
      final bound = (range >> 11) * probs[baseIndex + symbol];
      if (code < bound) {
        range = bound;
        probs[baseIndex + symbol] +=
            (2048 - probs[baseIndex + symbol]) >> 5;
        symbol = symbol << 1;
      } else {
        range -= bound;
        code -= bound;
        probs[baseIndex + symbol] -= probs[baseIndex + symbol] >> 5;
        symbol = (symbol << 1) | 1;
      }
    }
    return symbol & 0xff;
  }

  // Read a bittree (big endian) of [count] bits from the decoder.
  int readBittree(RangeDecoderTable table, int count) {
    var value = 0;
    var symbolPrefix = 1;
    for (var i = 0; i < count; i++) {
      final b = readBit(table, symbolPrefix | value);
      value = ((value << 1) | b) & 0xffffffff;
      symbolPrefix = (symbolPrefix << 1) & 0xffffffff;
    }

    return value;
  }

  // Read a reverse bittree (little endian) of [count] bits from the decoder.
  int readBittreeReverse(RangeDecoderTable table, int count) {
    var value = 0;
    var symbolPrefix = 1;
    for (var i = 0; i < count; i++) {
      final b = readBit(table, symbolPrefix | value);
      value = (value | b << i) & 0xffffffff;
      symbolPrefix = (symbolPrefix << 1) & 0xffffffff;
    }

    return value;
  }

  // Read [count] bits directly from the decoder.
  int readDirect(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      if (range < 0x1000000) {
        range <<= 8;
        code = (code << 8) | _buffer[_bufferPos++];
      }
      range >>= 1;
      code -= range;
      value <<= 1;
      if (code & 0x80000000 != 0) {
        code += range;
      } else {
        value++;
      }
    }
    return value;
  }
}

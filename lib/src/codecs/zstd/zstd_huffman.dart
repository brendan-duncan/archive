import 'dart:typed_data';

import 'zstd_bit_reader.dart';
import 'zstd_error.dart';
import 'zstd_fse.dart';

// Huffman coded literals, as described in RFC 8878 section 4.2.

/// The longest Huffman code zstd allows.
const int zstdHuffmanMaxBits = 12;

/// A Huffman decoding table, indexed by the next [maxBits] bits of a stream.
class ZstdHuffmanTable {
  /// Each entry holds the symbol in its low byte and the length of its code
  /// above that.
  final Uint16List entries = Uint16List(1 << zstdHuffmanMaxBits);

  int maxBits = 0;

  // Scratch space for reading a description.
  static final Uint8List _weights = Uint8List(256);
  static final ZstdFseTable _weightTable = ZstdFseTable(ZstdFseKind.plain, 6);
  static final ZstdBitReader _reader = ZstdBitReader();

  /// Reads a Huffman tree description starting at [pos] and builds the table
  /// from it, returning the position of the first byte after the description.
  int readDescription(Uint8List src, int pos, int end) {
    final int count;
    (count, pos) = readWeights(src, pos, end, _weights);
    _build(_weights, count);
    return pos;
  }

  /// Reads the weights from a Huffman tree description starting at [pos] into
  /// [weights], all but the last symbol's, returning how many there are and
  /// the position of the first byte after the description.
  static (int, int) readWeights(
      Uint8List src, int pos, int end, Uint8List weights) {
    if (pos >= end) {
      throw ZstdFormatError('Truncated Huffman tree description');
    }
    final header = src[pos++];
    int count;

    if (header >= 128) {
      // Weights stored directly, four bits each.
      count = header - 127;
      final size = (count + 1) >> 1;
      if (pos + size > end) {
        throw ZstdFormatError('Truncated Huffman tree description');
      }
      for (var i = 0; i < count; i += 2) {
        final b = src[pos + (i >> 1)];
        weights[i] = b >> 4;
        weights[i + 1] = b & 0xf;
      }
      pos += size;
    } else {
      // Weights compressed with FSE, two states interleaved.
      final size = header;
      final streamEnd = pos + size;
      if (size == 0 || streamEnd > end) {
        throw ZstdFormatError('Truncated Huffman tree description');
      }
      final table = _weightTable;
      final start = table.readDescription(src, pos, streamEnd);
      final br = _reader;
      if (!br.init(src, start, streamEnd)) {
        throw ZstdFormatError('Corrupt Huffman weight stream');
      }
      final log = table.accuracyLog;
      final symbol = table.symbol;
      final nbBits = table.nbBits;
      final stateBase = table.stateBase;
      var state1 = br.readBits(log);
      var state2 = br.readBits(log);
      // 255 weights at most, the last symbol's being implied.
      count = 0;
      for (;;) {
        if (count > 253) {
          throw ZstdFormatError('Too many Huffman weights');
        }
        weights[count++] = symbol[state1];
        state1 = stateBase[state1] + br.readBits(nbBits[state1]);
        if (br.isOverflowed) {
          weights[count++] = symbol[state2];
          break;
        }
        weights[count++] = symbol[state2];
        state2 = stateBase[state2] + br.readBits(nbBits[state2]);
        if (br.isOverflowed) {
          if (count > 254) {
            throw ZstdFormatError('Too many Huffman weights');
          }
          weights[count++] = symbol[state1];
          break;
        }
      }
      pos = streamEnd;
    }

    return (count, pos);
  }

  // Builds the table from the weights of all symbols but the last, whose
  // weight is whatever makes the code complete.
  void _build(Uint8List weights, int count) {
    var total = 0;
    for (var i = 0; i < count; i++) {
      final w = weights[i];
      if (w > zstdHuffmanMaxBits) {
        throw ZstdFormatError('Huffman weight $w too large');
      }
      if (w > 0) {
        total += 1 << (w - 1);
      }
    }
    if (total == 0) {
      throw ZstdFormatError('Huffman tree has no symbols');
    }
    final maxBits = total.bitLength;
    if (maxBits > zstdHuffmanMaxBits) {
      throw ZstdFormatError('Huffman tree too deep');
    }
    final rest = (1 << maxBits) - total;
    if (rest & (rest - 1) != 0) {
      throw ZstdFormatError('Huffman tree is incomplete');
    }
    weights[count] = rest.bitLength;
    final numSymbols = count + 1;

    // Codes of each length take a contiguous run of the table, the longest
    // codes first, and within a length the symbols are in order.
    final rankStart = Uint32List(zstdHuffmanMaxBits + 2);
    for (var i = 0; i < numSymbols; i++) {
      final w = weights[i];
      if (w > 0) {
        rankStart[w] += 1 << (w - 1);
      }
    }
    var next = 0;
    for (var w = 1; w <= maxBits; w++) {
      final current = next;
      next += rankStart[w];
      rankStart[w] = current;
    }

    final entries = this.entries;
    for (var s = 0; s < numSymbols; s++) {
      final w = weights[s];
      if (w == 0) {
        continue;
      }
      final entry = s | ((maxBits + 1 - w) << 8);
      final start = rankStart[w];
      final end = start + (1 << (w - 1));
      for (var i = start; i < end; i++) {
        entries[i] = entry;
      }
      rankStart[w] = end;
    }
    this.maxBits = maxBits;
  }

  /// Decodes [count] literals from the stream between [start] and [end] into
  /// [out], starting at [outPos].
  void decodeStream(Uint8List src, int start, int end, Uint8List out,
      int outPos, int count, ZstdBitReader br) {
    if (!br.init(src, start, end)) {
      throw ZstdFormatError('Corrupt Huffman stream');
    }
    final entries = this.entries;
    final maxBits = this.maxBits;
    final outEnd = outPos + count;
    var o = outPos;

    // As many symbols as one refill is sure to cover, without a check each.
    final perRefill = ZstdBitReader.bitsAfterRefill ~/ maxBits;
    final fastEnd = outEnd - perRefill;
    if (perRefill >= 4) {
      while (o <= fastEnd) {
        br.refill();
        var e = entries[br.peekBitsFast(maxBits)];
        out[o] = e;
        br.skipBits(e >> 8);
        e = entries[br.peekBitsFast(maxBits)];
        out[o + 1] = e;
        br.skipBits(e >> 8);
        e = entries[br.peekBitsFast(maxBits)];
        out[o + 2] = e;
        br.skipBits(e >> 8);
        e = entries[br.peekBitsFast(maxBits)];
        out[o + 3] = e;
        br.skipBits(e >> 8);
        o += 4;
      }
    } else if (perRefill >= 2) {
      while (o <= fastEnd) {
        br.refill();
        var e = entries[br.peekBitsFast(maxBits)];
        out[o] = e;
        br.skipBits(e >> 8);
        e = entries[br.peekBitsFast(maxBits)];
        out[o + 1] = e;
        br.skipBits(e >> 8);
        o += 2;
      }
    }
    while (o < outEnd) {
      final e = entries[br.peekBits(maxBits)];
      out[o++] = e;
      br.skipBits(e >> 8);
    }

    if (!br.isFinished) {
      throw ZstdFormatError('Huffman stream not fully consumed');
    }
  }
}

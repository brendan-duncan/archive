import 'dart:typed_data';

import 'zstd_bit_writer.dart';
import 'zstd_error.dart';
import 'zstd_fse_encoder.dart';
import 'zstd_huffman.dart';

/// The longest Huffman code the encoder makes, as the reference library does
/// by default. The format allows one bit more.
const int zstdHuffmanEncodeMaxBits = 11;

/// A Huffman code for literals.
class ZstdHuffmanEncoder {
  /// The length of each symbol's code, zero for symbols that do not occur.
  final Uint8List lengths = Uint8List(256);
  final Uint16List codes = Uint16List(256);
  int maxBits = 0;

  /// The largest symbol that occurs, whose weight the description leaves out.
  int maxSymbol = 0;

  final Uint8List _weights = Uint8List(256);
  final Uint8List _check = Uint8List(256);
  final Uint32List _weightCounts = Uint32List(16);
  final Int16List _norm = Int16List(16);
  final ZstdFseEncoder _fse = ZstdFseEncoder(6);
  final Uint8List _scratch = Uint8List(300);

  /// Builds an optimal code of at most [zstdHuffmanEncodeMaxBits] bits for
  /// [counts], the occurrences of each symbol up to [maxSymbol], at least two
  /// of which must occur.
  void build(Uint32List counts, int maxSymbol) {
    this.maxSymbol = maxSymbol;
    _packageMerge(counts, maxSymbol);

    var maxBits = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      if (lengths[s] > maxBits) {
        maxBits = lengths[s];
      }
    }
    this.maxBits = maxBits;

    // Canonical codes, laid out the way the decoder fills its table: the
    // longest codes first, and symbols in order within a length.
    final rankStart = Uint32List(maxBits + 2);
    for (var s = 0; s <= maxSymbol; s++) {
      final len = lengths[s];
      if (len != 0) {
        rankStart[maxBits + 1 - len] += 1 << (maxBits - len);
      }
    }
    var next = 0;
    for (var w = 1; w <= maxBits; w++) {
      final count = rankStart[w];
      rankStart[w] = next;
      next += count;
    }
    for (var s = 0; s <= maxSymbol; s++) {
      final len = lengths[s];
      if (len == 0) {
        codes[s] = 0;
        continue;
      }
      final w = maxBits + 1 - len;
      codes[s] = rankStart[w] >> (maxBits - len);
      rankStart[w] += 1 << (maxBits - len);
    }
  }

  // Length limited code lengths by package-merge: the 2n - 2 cheapest items
  // of the last list, each symbol's length being how many of them it is in.
  void _packageMerge(Uint32List counts, int maxSymbol) {
    final symbols = <int>[
      for (var s = 0; s <= maxSymbol; s++)
        if (counts[s] != 0) s
    ]..sort((a, b) => counts[a] != counts[b] ? counts[a] - counts[b] : a - b);
    final n = symbols.length;
    for (var s = 0; s <= maxSymbol; s++) {
      lengths[s] = 0;
    }

    // Leaves are nodes 0 to n - 1; packages follow.
    final weight = <int>[for (final s in symbols) counts[s]];
    final left = <int>[for (var i = 0; i < n; i++) -1];
    final right = <int>[for (var i = 0; i < n; i++) -1];
    final keep = 2 * n - 2;

    var list = <int>[for (var i = 0; i < n; i++) i];
    for (var level = 1; level < zstdHuffmanEncodeMaxBits; level++) {
      final merged = <int>[];
      var leaf = 0;
      var i = 0;
      while (merged.length < keep) {
        final hasPackage = i + 1 < list.length;
        if (leaf < n &&
            (!hasPackage ||
                weight[leaf] <= weight[list[i]] + weight[list[i + 1]])) {
          merged.add(leaf++);
        } else if (hasPackage) {
          weight.add(weight[list[i]] + weight[list[i + 1]]);
          left.add(list[i]);
          right.add(list[i + 1]);
          merged.add(weight.length - 1);
          i += 2;
        } else {
          break;
        }
      }
      list = merged;
    }

    final stack = <int>[];
    for (var k = 0; k < keep && k < list.length; k++) {
      stack.add(list[k]);
      while (stack.isNotEmpty) {
        final node = stack.removeLast();
        if (node < n) {
          lengths[symbols[node]]++;
        } else {
          stack
            ..add(left[node])
            ..add(right[node]);
        }
      }
    }
  }

  /// How many bits the literals counted in [counts] take with this code.
  int bitsFor(Uint32List counts) {
    var bits = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      bits += counts[s] * lengths[s];
    }
    return bits;
  }

  /// Writes the tree description at [pos], returning the position after it,
  /// or -1 if the code cannot be described.
  int writeDescription(Uint8List out, int pos, ZstdBitWriter writer) {
    final weights = _weights;
    final count = maxSymbol;
    for (var s = 0; s < count; s++) {
      final len = lengths[s];
      weights[s] = len == 0 ? 0 : maxBits + 1 - len;
    }

    // Weights compressed with FSE, if that works out smaller.
    final fseSize = _writeFseWeights(count, writer);
    final directSize = count <= 128 ? 1 + ((count + 1) >> 1) : -1;

    if (fseSize > 0 && (directSize < 0 || fseSize < directSize)) {
      out.setRange(pos, pos + fseSize, _scratch);
      return pos + fseSize;
    }
    if (directSize < 0) {
      return -1;
    }
    out[pos] = 127 + count;
    for (var i = 0; i < count; i += 2) {
      final low = i + 1 < count ? weights[i + 1] : 0;
      out[pos + 1 + (i >> 1)] = (weights[i] << 4) | low;
    }
    return pos + directSize;
  }

  // Compresses the weights into _scratch, header byte included, returning
  // the size or -1. The decoder knows where the weights end only from the
  // stream running out, so the result is decoded again to make sure it gives
  // back exactly these weights.
  int _writeFseWeights(int count, ZstdBitWriter writer) {
    if (count < 2) {
      return -1;
    }
    final weights = _weights;
    final counts = _weightCounts..fillRange(0, 16, 0);
    var maxWeight = 0;
    for (var i = 0; i < count; i++) {
      final w = weights[i];
      counts[w]++;
      if (w > maxWeight) {
        maxWeight = w;
      }
    }
    for (var w = 0; w <= maxWeight; w++) {
      if (counts[w] == count) {
        return -1;
      }
    }

    final log = zstdFseTableLog(count, maxWeight, 6);
    final numSymbols = zstdFseNormalize(counts, maxWeight, count, log, _norm);
    final fse = _fse..build(_norm, numSymbols, log);
    final out = _scratch;
    final start =
        zstdFseWriteDescription(out, 1, _norm, numSymbols, log, writer);

    writer.reset(out, start);
    var i = count;
    int state1;
    int state2;
    if (count & 1 != 0) {
      state1 = fse.initState(weights[--i]);
      state2 = fse.initState(weights[--i]);
      state1 = fse.encode(writer, state1, weights[--i]);
    } else {
      state2 = fse.initState(weights[--i]);
      state1 = fse.initState(weights[--i]);
    }
    while (i > 0) {
      state2 = fse.encode(writer, state2, weights[--i]);
      state1 = fse.encode(writer, state1, weights[--i]);
    }
    fse.flush(writer, state2);
    fse.flush(writer, state1);
    final end = writer.closeBackward();
    final size = end - 1;
    if (size >= 128) {
      return -1;
    }
    out[0] = size;

    try {
      final (decodedCount, decodedEnd) =
          ZstdHuffmanTable.readWeights(out, 0, end, _check);
      if (decodedCount != count || decodedEnd != end) {
        return -1;
      }
      for (var k = 0; k < count; k++) {
        if (_check[k] != weights[k]) {
          return -1;
        }
      }
    } on ZstdFormatError {
      return -1;
    }
    return end;
  }

  /// Writes the literals from [start] to [end] in [lit] as one Huffman
  /// stream, or four with a jump table before them, returning the position
  /// after them.
  int writeStreams(Uint8List lit, int start, int end, Uint8List out, int pos,
      bool fourStreams, ZstdBitWriter writer) {
    if (!fourStreams) {
      return _writeStream(lit, start, end, out, pos, writer);
    }
    final segment = (end - start + 3) >> 2;
    var p = pos + 6;
    for (var k = 0; k < 4; k++) {
      final s = start + k * segment;
      final e = k == 3 ? end : s + segment;
      final next = _writeStream(lit, s, e, out, p, writer);
      if (k < 3) {
        final size = next - p;
        out[pos + 2 * k] = size & 0xff;
        out[pos + 2 * k + 1] = size >> 8;
      }
      p = next;
    }
    return p;
  }

  int _writeStream(Uint8List lit, int start, int end, Uint8List out, int pos,
      ZstdBitWriter writer) {
    writer.reset(out, pos);
    final codes = this.codes;
    final lengths = this.lengths;
    // Backwards, so the decoder meets the first literal first
    for (var i = end - 1; i >= start; i--) {
      final s = lit[i];
      writer.addBits(codes[s], lengths[s]);
    }
    return writer.closeBackward();
  }
}

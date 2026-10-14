import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_fse_encoder.dart';
import 'zstd_huffman_encoder.dart';
import 'zstd_match_finder.dart';
import 'zstd_sequences_encoder.dart';

/// A price is in 256ths of a bit. That resolution chooses between two parses
/// differing by a fraction of a bit per symbol
const zstdPriceBits = 8;
const zstdPriceOne = 1 << zstdPriceBits;
const zstdPriceMax = 1 << 30;

const _litFreqAdd = 2;

/// Below this the block is too short for its own statistics to mean anything
const _predefThreshold = 8;

/// What the optimal parse thinks a symbol costs, from frequencies it keeps
/// across the blocks of a frame. `optState_t` and the price functions of
/// `zstd_opt.c`
class ZstdOptPrices {
  final Uint32List litFreq = Uint32List(256);
  final Uint32List litLengthFreq = Uint32List(zstdLiteralsLengthCodeMax + 1);
  final Uint32List matchLengthFreq = Uint32List(zstdMatchLengthCodeMax + 1);
  final Uint32List offCodeFreq = Uint32List(zstdOffsetCodeMax + 1);

  int litSum = 0;
  int litLengthSum = 0;
  int matchLengthSum = 0;
  int offCodeSum = 0;

  /// The weight of every table entry, kept beside the frequency it came from.
  /// A frequency changes only when a sequence is recorded, while a weight is
  /// asked for on every candidate the parse considers
  final Uint32List _litWeight = Uint32List(256);
  final Uint32List _litLengthWeight = Uint32List(zstdLiteralsLengthCodeMax + 1);
  final Uint32List _matchLengthWeight = Uint32List(zstdMatchLengthCodeMax + 1);
  final Uint32List _offCodeWeight = Uint32List(zstdOffsetCodeMax + 1);

  int _litBase = 0;
  int _litLengthBase = 0;
  int _matchLengthBase = 0;
  int _offCodeBase = 0;

  /// Zero prices a symbol in whole bits, the way `btopt` does. One and
  /// above interpolate between them, for `btultra` and `btultra2`
  int level = 0;
  bool _predef = false;

  /// The tables a dictionary gave the decoder. A first block prices from
  /// what they say a symbol costs rather than from its own bytes
  ZstdHuffmanEncoder? dictionaryTree;
  ZstdFseCTable? dictionaryLitLengths;
  ZstdFseCTable? dictionaryOffsets;
  ZstdFseCTable? dictionaryMatchLengths;

  void reset() {
    litSum = 0;
    litLengthSum = 0;
    matchLengthSum = 0;
    offCodeSum = 0;
  }

  @pragma('vm:prefer-inline')
  int _weight(int stat) {
    final value = stat + 1;
    final top = zstdHighestBit(value);
    if (level == 0) {
      return top << zstdPriceBits;
    }
    return (top << zstdPriceBits) + ((value << zstdPriceBits) >> top);
  }

  /// Seeds the frequencies for a block: from the block's own bytes on the
  /// first one, from what the frame has seen on every later one
  void rescale(Uint8List src, int start, int end) {
    _predef = false;
    if (litLengthSum == 0) {
      if (end - start <= _predefThreshold) {
        _predef = true;
      }
      final tree = dictionaryTree;
      if (tree != null) {
        _seedFromDictionary(tree);
        _rebuildWeights();
        setBases();
        return;
      }
      litFreq.fillRange(0, litFreq.length, 0);
      for (var i = start; i < end; i++) {
        litFreq[src[i]]++;
      }
      litSum = _downscale(litFreq, 8, guaranteed: false);
      litLengthFreq.fillRange(0, litLengthFreq.length, 1);
      litLengthFreq[0] = 4;
      litLengthFreq[1] = 2;
      litLengthSum = _sum(litLengthFreq);
      matchLengthFreq.fillRange(0, matchLengthFreq.length, 1);
      matchLengthSum = matchLengthFreq.length;
      offCodeFreq.fillRange(0, offCodeFreq.length, 1);
      const baseOffCodes = [6, 2, 1, 1, 2, 3, 4, 4, 4, 3, 2];
      for (var i = 0; i < baseOffCodes.length; i++) {
        offCodeFreq[i] = baseOffCodes[i];
      }
      offCodeSum = _sum(offCodeFreq);
    } else {
      litSum = _scale(litFreq, 12);
      litLengthSum = _scale(litLengthFreq, 11);
      matchLengthSum = _scale(matchLengthFreq, 11);
      offCodeSum = _scale(offCodeFreq, 11);
    }
    _rebuildWeights();
    setBases();
  }

  /// `ZSTD_rescaleFreqs`' dictionary branch: a frequency is read back out of
  /// what the table charges for the symbol, scaled so the widest code is one
  /// and every symbol keeps a frequency of at least one
  void _seedFromDictionary(ZstdHuffmanEncoder tree) {
    _predef = false;
    litSum = 0;
    for (var lit = 0; lit < litFreq.length; lit++) {
      final bits = tree.bitsOf(lit);
      final points = bits != 0 ? 1 << (11 - bits) : 1;
      litFreq[lit] = points;
      litSum += points;
    }
    litLengthSum =
        _seedTable(litLengthFreq, dictionaryLitLengths, litLengthFreq.length);
    matchLengthSum = _seedTable(
        matchLengthFreq, dictionaryMatchLengths, matchLengthFreq.length);
    offCodeSum = _seedTable(offCodeFreq, dictionaryOffsets, offCodeFreq.length);
  }

  static int _seedTable(Uint32List into, ZstdFseCTable? table, int length) {
    var total = 0;
    for (var s = 0; s < length; s++) {
      final bits = table == null ? 0 : table.maxBits(s);
      final points = bits != 0 ? 1 << (10 - bits) : 1;
      into[s] = points;
      total += points;
    }
    return total;
  }

  void _rebuildWeights() {
    for (var i = 0; i < 256; i++) {
      _litWeight[i] = _weight(litFreq[i]);
    }
    for (var i = 0; i < litLengthFreq.length; i++) {
      _litLengthWeight[i] = _weight(litLengthFreq[i]);
    }
    for (var i = 0; i < matchLengthFreq.length; i++) {
      _matchLengthWeight[i] = _weight(matchLengthFreq[i]);
    }
    for (var i = 0; i < offCodeFreq.length; i++) {
      _offCodeWeight[i] = _weight(offCodeFreq[i]);
    }
  }

  void setBases() {
    _litBase = _weight(litSum);
    _litLengthBase = _weight(litLengthSum);
    _matchLengthBase = _weight(matchLengthSum);
    _offCodeBase = _weight(offCodeSum);
  }

  static int _sum(Uint32List table) {
    var total = 0;
    for (var i = 0; i < table.length; i++) {
      total += table[i];
    }
    return total;
  }

  int _downscale(Uint32List table, int shift, {required bool guaranteed}) {
    var total = 0;
    for (var i = 0; i < table.length; i++) {
      final base = guaranteed ? 1 : (table[i] > 0 ? 1 : 0);
      final scaled = base + (table[i] >> shift);
      table[i] = scaled;
      total += scaled;
    }
    return total;
  }

  int _scale(Uint32List table, int targetLog) {
    final previous = _sum(table);
    final factor = previous >> targetLog;
    if (factor <= 1) {
      return previous;
    }
    return _downscale(table, zstdHighestBit(factor), guaranteed: true);
  }

  /// The literals themselves, without the symbol for their count
  int literalsPrice(Uint8List src, int at, int length) {
    if (length == 0) {
      return 0;
    }
    if (_predef) {
      return length * 6 * zstdPriceOne;
    }
    var price = _litBase * length;
    final ceiling = _litBase - zstdPriceOne;
    for (var i = 0; i < length; i++) {
      var one = _litWeight[src[at + i]];
      if (one > ceiling) {
        one = ceiling;
      }
      price -= one;
    }
    return price;
  }

  int litLengthPrice(int litLength) {
    if (_predef) {
      return _weight(litLength);
    }
    if (litLength == zstdBlockMaximumSize) {
      return (1 << zstdPriceBits) + litLengthPrice(zstdBlockMaximumSize - 1);
    }
    final code = zstdLiteralsLengthCode(litLength);
    return (zstdLiteralsLengthExtraBits[code] << zstdPriceBits) +
        _litLengthBase -
        _litLengthWeight[code];
  }

  /// The offset and the length of a match, in the same units. [offBase] is the
  /// stored form: one to three name a repeat, anything above is offset plus
  /// three
  int matchPrice(int offBase, int matchLength) {
    final offCode = zstdHighestBit(offBase);
    final mlBase = matchLength - zstdMatchLengthFloor;
    if (_predef) {
      return _weight(mlBase) + ((16 + offCode) << zstdPriceBits);
    }
    var price =
        (offCode << zstdPriceBits) + (_offCodeBase - _offCodeWeight[offCode]);
    // A distant offset is charged extra below btultra, where the parse is
    // meant to leave the decoder's cache alone
    if (level < 2 && offCode >= 20) {
      price += (offCode - 19) * 2 * zstdPriceOne;
    }
    final mlCode = zstdMatchLengthCode(mlBase);
    price += (zstdMatchLengthExtraBits[mlCode] << zstdPriceBits) +
        (_matchLengthBase - _matchLengthWeight[mlCode]);
    // Nudges the parse towards fewer, longer sequences
    return price + zstdPriceOne ~/ 5;
  }

  /// [offBase] one to three names a repeat, anything above is offset plus three
  int matchOffsetPrice(int offBase) {
    final offCode = zstdHighestBit(offBase);
    if (_predef) {
      return (16 + offCode) << zstdPriceBits;
    }
    var price =
        (offCode << zstdPriceBits) + (_offCodeBase - _offCodeWeight[offCode]);
    // A distant offset is charged extra below btultra, where the parse is
    // meant to leave the decoder's cache alone
    if (level < 2 && offCode >= 20) {
      price += (offCode - 19) * 2 * zstdPriceOne;
    }
    // Nudges the parse towards fewer, longer sequences
    return price + zstdPriceOne ~/ 5;
  }

  int matchLengthPrice(int matchLength) {
    final mlBase = matchLength - zstdMatchLengthFloor;
    if (_predef) {
      return _weight(mlBase);
    }
    final mlCode = zstdMatchLengthCode(mlBase);
    return (zstdMatchLengthExtraBits[mlCode] << zstdPriceBits) +
        (_matchLengthBase - _matchLengthWeight[mlCode]);
  }

  void record(
      Uint8List src, int at, int litLength, int offBase, int matchLength) {
    for (var i = 0; i < litLength; i++) {
      final byte = src[at + i];
      final grown = litFreq[byte] + _litFreqAdd;
      litFreq[byte] = grown;
      _litWeight[byte] = _weight(grown);
    }
    litSum += litLength * _litFreqAdd;
    final ll = zstdLiteralsLengthCode(litLength);
    _litLengthWeight[ll] = _weight(++litLengthFreq[ll]);
    litLengthSum++;
    final of = zstdHighestBit(offBase);
    _offCodeWeight[of] = _weight(++offCodeFreq[of]);
    offCodeSum++;
    final ml = zstdMatchLengthCode(matchLength - zstdMatchLengthFloor);
    _matchLengthWeight[ml] = _weight(++matchLengthFreq[ml]);
    matchLengthSum++;
  }
}

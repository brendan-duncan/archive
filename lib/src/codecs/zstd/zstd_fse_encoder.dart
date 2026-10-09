import 'dart:math' as math;
import 'dart:typed_data';

import 'zstd_bit_writer.dart';
import 'zstd_fse.dart';

/// An FSE encoding table, for the Huffman weights and the sequence fields.
///
/// Encoding runs backwards: the first symbol given to [initState] is the last
/// one the decoder produces. A state is kept between 2^[tableLog] and twice
/// that, and its low [tableLog] bits are the decoder's state.
class ZstdFseEncoder {
  int tableLog = 0;

  /// The probabilities this table was built from, kept for estimating what
  /// reusing it for another block would cost.
  final Int16List norm = Int16List(256);
  int numSymbols = 0;

  final Uint16List _stateTable;
  final Int32List _deltaNbBits = Int32List(256);
  final Int32List _deltaFindState = Int32List(256);

  // Shares the decoder's code for spreading symbols through the table, which
  // both sides have to do identically.
  final ZstdFseTable _spread;

  ZstdFseEncoder(int maxLog)
      : _stateTable = Uint16List(1 << maxLog),
        _spread = ZstdFseTable(ZstdFseKind.plain, maxLog);

  /// Builds the table from [numSymbols] probabilities in [norm], which sum to
  /// 2^[log], with -1 standing for a probability below one.
  void build(List<int> norm, int numSymbols, int log) {
    for (var s = 0; s < numSymbols; s++) {
      this.norm[s] = norm[s];
    }
    this.numSymbols = numSymbols;
    tableLog = log;
    final size = 1 << log;

    _spread.build(this.norm, numSymbols, log);
    final symbol = _spread.symbol;

    // Each symbol's states, in the order their table positions come.
    final cumul = Int32List(numSymbols + 1);
    for (var s = 0; s < numSymbols; s++) {
      final n = norm[s];
      cumul[s + 1] = cumul[s] + (n == -1 ? 1 : n);
    }
    for (var u = 0; u < size; u++) {
      _stateTable[cumul[symbol[u]]++] = size + u;
    }

    var total = 0;
    for (var s = 0; s < numSymbols; s++) {
      final n = norm[s];
      if (n == 0) {
        _deltaNbBits[s] = ((log + 1) << 16) - size;
      } else if (n == -1 || n == 1) {
        _deltaNbBits[s] = (log << 16) - size;
        _deltaFindState[s] = total - 1;
        total++;
      } else {
        final maxBitsOut = log - ((n - 1).bitLength - 1);
        final minStatePlus = n << maxBitsOut;
        _deltaNbBits[s] = (maxBitsOut << 16) - minStatePlus;
        _deltaFindState[s] = total - n;
        total += n;
      }
    }
  }

  /// The state to start from for [symbol], the last to be decoded. It costs
  /// no bits.
  int initState(int symbol) {
    final nbBitsOut = (_deltaNbBits[symbol] + (1 << 15)) >> 16;
    final value = (nbBitsOut << 16) - _deltaNbBits[symbol];
    return _stateTable[(value >> nbBitsOut) + _deltaFindState[symbol]];
  }

  /// Encodes [symbol] from [state], writing the bits that take the decoder
  /// back, and returns the new state.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  int encode(ZstdBitWriter writer, int state, int symbol) {
    final nbBitsOut = (state + _deltaNbBits[symbol]) >> 16;
    writer.addBits(state & ((1 << nbBitsOut) - 1), nbBitsOut);
    return _stateTable[(state >> nbBitsOut) + _deltaFindState[symbol]];
  }

  /// Writes [state] for the decoder to start from.
  void flush(ZstdBitWriter writer, int state) {
    writer.addBits(state & ((1 << tableLog) - 1), tableLog);
  }

  /// Roughly how many bits [counts] would take to encode with this table, or
  /// null if it has no state for one of the symbols they use.
  double? cost(Uint32List counts, int maxSymbol) =>
      zstdFseCost(counts, maxSymbol, norm, numSymbols, tableLog);
}

/// Roughly how many bits [counts] take to encode with the table [norm]
/// describes, or null if that has no state for one of the symbols they use.
double? zstdFseCost(Uint32List counts, int maxSymbol, List<int> norm,
    int numSymbols, int tableLog) {
  var bits = 0.0;
  for (var s = 0; s <= maxSymbol; s++) {
    final c = counts[s];
    if (c == 0) {
      continue;
    }
    final n = s < numSymbols ? norm[s] : 0;
    if (n == 0) {
      return null;
    }
    bits += c * (tableLog - _log2(n == -1 ? 1 : n));
  }
  return bits;
}

final Float64List _log2Table = () {
  final t = Float64List(4097);
  for (var i = 1; i < t.length; i++) {
    t[i] = math.log(i) / math.ln2;
  }
  return t;
}();

double _log2(int n) =>
    n < _log2Table.length ? _log2Table[n] : math.log(n) / math.ln2;

/// Picks the accuracy log for a table encoding [total] symbols, none greater
/// than [maxSymbol], at most [maxLog].
int zstdFseTableLog(int total, int maxSymbol, int maxLog) {
  // As the reference library picks it. No point in many more states than
  // symbols to encode, but enough that every symbol that occurs has room.
  var log = maxLog;
  final fromTotal = (total - 1).bitLength - 3;
  if (fromTotal < log) {
    log = fromTotal;
  }
  final minimum = math.min(total.bitLength, maxSymbol.bitLength + 1);
  if (minimum > log) {
    log = minimum;
  }
  if (log < 5) {
    log = 5;
  }
  return log > maxLog ? maxLog : log;
}

/// Scales [counts] of the symbols up to [maxSymbol], which sum to [total],
/// to probabilities that sum to 2^[log], giving every symbol that occurs at
/// least one. Returns the number of symbols the result covers.
int zstdFseNormalize(
    Uint32List counts, int maxSymbol, int total, int log, Int16List norm) {
  final size = 1 << log;
  var distributed = 0;
  var largest = 0;
  var largestNorm = 0;
  for (var s = 0; s <= maxSymbol; s++) {
    final c = counts[s];
    if (c == 0) {
      norm[s] = 0;
      continue;
    }
    var n = (c * size + (total >> 1)) ~/ total;
    if (n < 1) {
      n = 1;
    }
    norm[s] = n;
    distributed += n;
    if (n > largestNorm) {
      largestNorm = n;
      largest = s;
    }
  }

  var diff = size - distributed;
  if (diff > 0 || largestNorm + diff >= (largestNorm + 1) >> 1) {
    // Usually the largest probability can absorb the rounding on its own
    norm[largest] += diff;
  } else {
    // Otherwise take from whichever probabilities are largest at the time
    while (diff < 0) {
      var best = -1;
      for (var s = 0; s <= maxSymbol; s++) {
        if (norm[s] > 1 && (best < 0 || norm[s] > norm[best])) {
          best = s;
        }
      }
      norm[best]--;
      diff++;
    }
  }
  return maxSymbol + 1;
}

/// Writes the table description for [norm], [numSymbols] probabilities
/// summing to 2^[log], returning the position after it.
int zstdFseWriteDescription(Uint8List out, int pos, List<int> norm,
    int numSymbols, int log, ZstdBitWriter writer) {
  writer.reset(out, pos);
  writer.addBits(log - 5, 4);

  // The exact mirror of ZstdFseTable.readDescription.
  var remaining = (1 << log) + 1;
  var threshold = 1 << log;
  var bits = log + 1;
  var symbol = 0;
  var previousZero = false;
  while (remaining > 1) {
    if (previousZero) {
      var run = 0;
      while (norm[symbol] == 0) {
        symbol++;
        run++;
      }
      while (run >= 3) {
        writer.addBits(3, 2);
        run -= 3;
      }
      writer.addBits(run, 2);
    }
    final count = norm[symbol++];
    final value = count + 1;
    final max = (2 * threshold - 1) - remaining;
    if (value < max) {
      writer.addBits(value, bits - 1);
    } else {
      writer.addBits(value >= threshold ? value + max : value, bits);
    }
    remaining -= count < 0 ? -count : count;
    previousZero = count == 0;
    if (remaining < threshold) {
      bits = remaining.bitLength;
      threshold = 1 << (bits - 1);
    }
  }
  assert(symbol <= numSymbols);
  return writer.closeForward();
}

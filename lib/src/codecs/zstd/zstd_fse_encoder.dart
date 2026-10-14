import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_bit_writer.dart';
import 'zstd_constants.dart';
import 'zstd_fse.dart';
import 'zstd_web.dart';

class ZstdFseEncoderException extends ArchiveException {
  ZstdFseEncoderException(super.message);
  @override
  String toString() => 'ZstdFseEncoderException: $message';
}

/// Rounding thresholds libzstd uses to decide whether a probability below eight
/// is worth one more point, as twenty bit fractions
const _roundUpAt = [0, 473195, 504333, 520860, 550000, 700000, 750000, 830000];

/// Smallest accuracy that can still hold every symbol apart
int zstdMinTableLog(int total, int maxSymbol) {
  final fromSize = zstdHighestBit(total) + 1;
  final fromSymbols = zstdHighestBit(maxSymbol) + 2;
  return fromSize < fromSymbols ? fromSize : fromSymbols;
}

/// The accuracy to normalize to: as much as the data can justify, bounded by
/// what the section allows
int zstdOptimalTableLog(int maxLog, int total, int maxSymbol) {
  if (total <= 1) {
    return 5;
  }
  var log = maxLog;
  // The reference holds this in an unsigned word, so a total of four or less
  // wraps it past every table log instead of shrinking one
  final fromSize = zstdHighestBit(total - 1) - 2;
  if (fromSize >= 0 && fromSize < log) {
    log = fromSize;
  }
  final least = zstdMinTableLog(total, maxSymbol);
  if (least > log) {
    log = least;
  }
  if (log < 5) {
    log = 5;
  }
  return log > maxLog ? maxLog : log;
}

/// Scales [counts] to exactly `1 << accuracyLog` points in [into].
///
/// A symbol too rare to earn a point gets -1, which the format reads as less
/// than one and which costs a full state reset. Returns false when one symbol
/// takes everything, and such a table is written as RLE instead
bool zstdNormalizeCount(Int16List into, Uint32List counts, int total,
    int maxSymbol, int accuracyLog,
    {bool useLowProbCount = true}) {
  final lowProb = useLowProbCount ? -1 : 1;
  final lowThreshold = total >> accuracyLog;
  // The reference's own fixed point: a step of `2^62 / total` truncated once,
  // which is not the same as dividing per symbol and rounds a knife edge down
  final scale = 62 - accuracyLog;
  final step = (1 << 62) ~/ total;
  final vStep = 1 << (scale - 20);
  final webScale =
      zstdUse64Bit ? null : ZstdFseScale.normalize(total, accuracyLog);
  var left = 1 << accuracyLog;
  var largest = 0;
  var largestPoints = 0;

  for (var s = 0; s <= maxSymbol; s++) {
    final count = counts[s];
    if (count == total) {
      return false;
    }
    if (count == 0) {
      into[s] = 0;
      continue;
    }
    if (count <= lowThreshold) {
      into[s] = lowProb;
      left--;
      continue;
    }
    int points;
    if (webScale == null) {
      final scaled = count * step;
      points = scaled >> scale;
      if (points < 8 &&
          scaled - (points << scale) > vStep * _roundUpAt[points]) {
        points++;
      }
    } else {
      points = webScale.probability(count, _roundUpAt);
    }
    if (points > largestPoints) {
      largestPoints = points;
      largest = s;
    }
    into[s] = points;
    left -= points;
  }

  if (-left >= into[largest] >> 1) {
    _spreadRemainder(into, counts, total, maxSymbol, accuracyLog, lowProb);
  } else {
    into[largest] += left;
  }
  return true;
}

/// `FSE_normalizeM2`, the fallback for when taking the remainder out of the
/// largest symbol would take more than half of it. Symbols too rare to earn a
/// point are settled first, the rest share the remainder by a scaled pass
void _spreadRemainder(Int16List into, Uint32List counts, int total,
    int maxSymbol, int accuracyLog, int lowProb) {
  const notYet = -2;
  var distributed = 0;
  var left = total;
  final lowThreshold = total >> accuracyLog;
  var lowOne = (total * 3) >> (accuracyLog + 1);
  for (var s = 0; s <= maxSymbol; s++) {
    final count = counts[s];
    if (count == 0) {
      into[s] = 0;
    } else if (count <= lowThreshold) {
      into[s] = lowProb;
      distributed++;
      left -= count;
    } else if (count <= lowOne) {
      into[s] = 1;
      distributed++;
      left -= count;
    } else {
      into[s] = notYet;
    }
  }
  var toGive = (1 << accuracyLog) - distributed;
  if (toGive == 0) {
    return;
  }
  // Where a point each would still round the rest to zero, more symbols are
  // held at one and the share is recomputed
  if (left ~/ toGive > lowOne) {
    lowOne = (left * 3) ~/ (toGive * 2);
    for (var s = 0; s <= maxSymbol; s++) {
      if (into[s] == notYet && counts[s] <= lowOne) {
        into[s] = 1;
        distributed++;
        left -= counts[s];
      }
    }
    toGive = (1 << accuracyLog) - distributed;
  }
  if (distributed == maxSymbol + 1) {
    var at = 0;
    var most = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      if (counts[s] > most) {
        at = s;
        most = counts[s];
      }
    }
    into[at] += toGive;
    return;
  }
  if (left == 0) {
    var s = 0;
    while (toGive > 0) {
      if (into[s] > 0) {
        toGive--;
        into[s]++;
      }
      s = (s + 1) % (maxSymbol + 1);
    }
    return;
  }
  final stepLog = 62 - accuracyLog;
  if (!zstdUse64Bit) {
    final scale = ZstdFseScale.remainder(left, toGive, accuracyLog);
    for (var s = 0; s <= maxSymbol; s++) {
      if (into[s] == notYet) {
        final weight = scale.advance(counts[s]);
        if (weight < 1) {
          throw ZstdFseEncoderException(
              'Accuracy of $accuracyLog is too small for $maxSymbol symbols');
        }
        into[s] = weight;
      }
    }
    return;
  }
  final mid = (1 << (stepLog - 1)) - 1;
  final step = ((1 << stepLog) * toGive + mid) ~/ left;
  var running = mid;
  for (var s = 0; s <= maxSymbol; s++) {
    if (into[s] == notYet) {
      final end = running + counts[s] * step;
      final weight = (end >> stepLog) - (running >> stepLog);
      if (weight < 1) {
        throw ZstdFseEncoderException(
            'Accuracy of $accuracyLog is too small for $maxSymbol symbols');
      }
      into[s] = weight;
      running = end;
    }
  }
}

/// Writes the table description, the exact inverse of [readFseDistribution].
/// Returns the bytes it occupied
int zstdWriteNCount(
    Uint8List out, int at, Int16List counts, int maxSymbol, int accuracyLog) {
  final tableSize = 1 << accuracyLog;
  var stream = accuracyLog - 5;
  var bits = 4;
  var remaining = tableSize + 1;
  var threshold = tableSize;
  var nbBits = accuracyLog + 1;
  var symbol = 0;
  var previousIsZero = false;
  var write = at;

  while (symbol <= maxSymbol && remaining > 1) {
    if (previousIsZero) {
      var start = symbol;
      while (symbol <= maxSymbol && counts[symbol] == 0) {
        symbol++;
      }
      if (symbol > maxSymbol) {
        break;
      }
      // Runs of 24 are written as three escapes in a row. A long gap costs two
      // bytes that way rather than one pair per three symbols
      while (symbol >= start + 24) {
        start += 24;
        stream |= 0xffff << bits;
        out[write++] = stream & 0xff;
        out[write++] = (stream >> 8) & 0xff;
        stream >>= 16;
      }
      while (symbol >= start + 3) {
        start += 3;
        stream |= 3 << bits;
        bits += 2;
      }
      stream |= (symbol - start) << bits;
      bits += 2;
      if (bits > 16) {
        out[write++] = stream & 0xff;
        out[write++] = (stream >> 8) & 0xff;
        stream >>= 16;
        bits -= 16;
      }
    }

    var count = counts[symbol++];
    final max = (threshold << 1) - 1 - remaining;
    remaining -= count < 0 ? -count : count;
    count++;
    if (count >= threshold) {
      count += max;
    }
    stream |= count << bits;
    bits += nbBits;
    if (count < max) {
      bits--;
    }
    previousIsZero = count == 1;
    if (remaining < 1) {
      throw ZstdFseEncoderException('Probabilities overshoot the table size');
    }
    while (remaining < threshold) {
      nbBits--;
      threshold >>= 1;
    }

    if (bits > 16) {
      out[write++] = stream & 0xff;
      out[write++] = (stream >> 8) & 0xff;
      stream >>= 16;
      bits -= 16;
    }
  }

  if (remaining != 1) {
    throw ZstdFseEncoderException('Probabilities do not add up to the table');
  }
  out[write] = stream & 0xff;
  out[write + 1] = (stream >> 8) & 0xff;
  return write + ((bits + 7) >> 3) - at;
}

/// The encoding side of an FSE table: where each state goes and what it costs.
///
/// `nbBits` out of a state is `(state + deltaNbBits) >> 16`. That trick turns a
/// comparison into an add. The next state is
/// `nextState[(state >> nbBits) + deltaFindState]`
class ZstdFseCTable {
  final Uint16List nextState;

  /// `FSE_symbolCompressionTransform`, which the reference reads as one eight
  /// byte value: the bit delta in the high half, the state delta in the low
  final TypedData symbolTT;
  int accuracyLog = 0;

  /// The highest symbol this table was built for, above which its deltas hold
  /// whatever an older build left there
  int maxSymbol = -1;

  /// The cast keeps the SDK 3.0 floor: before 3.13 a conditional between two
  /// typed lists infers `List<int>` and the field will not take it
  ZstdFseCTable(int maxLog, int maxSymbolCount)
      : nextState = Uint16List(1 << maxLog),
        symbolTT = (zstdUse64Bit
            ? Int64List(maxSymbolCount)
            : Int32List(maxSymbolCount * 2)) as TypedData;

  void build(Int16List counts, int maxSymbol, int accuracyLog, Uint8List spread,
      Uint16List scratch, Uint32List cumulative) {
    final tableSize = 1 << accuracyLog;
    this.accuracyLog = accuracyLog;
    this.maxSymbol = maxSymbol;

    cumulative[0] = 0;
    for (var s = 1; s <= maxSymbol + 1; s++) {
      final count = counts[s - 1];
      cumulative[s] = cumulative[s - 1] + (count == -1 ? 1 : count);
    }
    zstdSpreadSymbols(counts, maxSymbol, tableSize, spread, scratch);

    for (var state = 0; state < tableSize; state++) {
      final symbol = spread[state];
      nextState[cumulative[symbol]++] = tableSize + state;
    }

    var total = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      final count = counts[s];
      final int bits;
      final int find;
      if (count == 0) {
        bits = ((accuracyLog + 1) << 16) - tableSize;
        find = 0;
      } else if (count == -1 || count == 1) {
        bits = (accuracyLog << 16) - tableSize;
        find = total - 1;
        total++;
      } else {
        final maxBits = accuracyLog - zstdHighestBit(count - 1);
        bits = (maxBits << 16) - (count << maxBits);
        find = total - count;
        total += count;
      }
      if (zstdUse64Bit) {
        (symbolTT as Int64List)[s] = (bits << 32) | (find & 0xffffffff);
      } else {
        final table = symbolTT as Int32List;
        table[s * 2] = bits;
        table[s * 2 + 1] = find;
      }
    }
  }

  /// `FSE_getMaxNbBits`: the widest this symbol can be, in whole bits
  int maxBits(int symbol) =>
      ((zstdUse64Bit
              ? (symbolTT as Int64List)[symbol] >> 32
              : (symbolTT as Int32List)[symbol * 2]) +
          (1 << 16) -
          1) >>
      16;

  /// The state the last symbol of a stream starts from, which costs no bits
  @pragma('vm:prefer-inline')
  int initialState(int symbol) {
    if (!zstdUse64Bit) {
      final table = symbolTT as Int32List;
      final delta = table[symbol * 2];
      final nbBits = (delta + (1 << 15)) >> 16;
      final value = (nbBits << 16) - delta;
      return nextState[(value >> nbBits) + table[symbol * 2 + 1]];
    }
    final packed = (symbolTT as Int64List)[symbol];
    final delta = packed >> 32;
    final nbBits = (delta + (1 << 15)) >> 16;
    final value = (nbBits << 16) - delta;
    return nextState[(value >> nbBits) + ((packed << 32) >> 32)];
  }

  /// What [symbol] costs here in 256ths of a bit. A symbol the table gives no
  /// probability at all reads as one bit past the accuracy. We compare
  /// against that value to reject a table we cannot use
  int bitCost(int symbol) {
    final delta = zstdUse64Bit
        ? (symbolTT as Int64List)[symbol] >> 32
        : (symbolTT as Int32List)[symbol * 2];
    final least = delta >> 16;
    final beyond = ((least + 1) << 16) - (delta + (1 << accuracyLog));
    return ((least + 1) << 8) - ((beyond << 8) >> accuracyLog);
  }

  int get badCost => (accuracyLog + 1) << 8;

  /// Writes the low bits of [state] and returns the state [symbol] leads to.
  /// The counts are masked so the shifts compile without a range guard
  @pragma('vm:prefer-inline')
  int encode(ZstdBitWriter out, int state, int symbol) {
    if (!zstdUse64Bit) {
      final table = symbolTT as Int32List;
      final nbBits = ((state + table[symbol * 2]) >> 16) & 63;
      out.add(state, nbBits);
      return nextState[(state >> nbBits) + table[symbol * 2 + 1]];
    }
    final packed = (symbolTT as Int64List)[symbol];
    final nbBits = ((state + (packed >> 32)) >> 16) & 63;
    out.add(state, nbBits);
    return nextState[(state >> nbBits) + ((packed << 32) >> 32)];
  }
}

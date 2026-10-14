import 'dart:typed_data';

import '../../util/archive_exception.dart';

import 'zstd_constants.dart';

/// One packed row per state:
///
/// ```
/// bits  0..7   symbol
/// bits  8..15  bits to read for the next state
/// bits 16..31  baseline to add to them
/// ```
class ZstdFseTable {
  Uint32List rows;
  int accuracyLog;

  ZstdFseTable(int maxLog)
      : rows = Uint32List(1 << maxLog),
        accuracyLog = 0;

  @pragma('vm:prefer-inline')
  int get size => 1 << accuracyLog;

  @pragma('vm:prefer-inline')
  int get mask => (1 << accuracyLog) - 1;

  void setRle(int symbol) {
    accuracyLog = 0;
    rows[0] = symbol;
  }
}

class ZstdFseDistribution {
  /// -1 means a probability of less than one
  final Int16List counts;
  final int maxSymbol;
  final int accuracyLog;
  final int bytesRead;

  ZstdFseDistribution(
      this.counts, this.maxSymbol, this.accuracyLog, this.bytesRead);
}

class ZstdFseException extends ArchiveException {
  ZstdFseException(super.message);
  @override
  String toString() => 'ZstdFseException: $message';
}

/// [end] bounds the available input, not the description, whose length is only
/// known once it has been read. [counts] is written in place over
/// `0..maxSymbolValue`
ZstdFseDistribution readFseDistribution(
    Uint8List data, int start, int end, Int16List counts, int maxSymbolValue,
    {required int maxAccuracyLog}) {
  if (start >= end) {
    _tableDescriptionIsEmpty();
  }
  // A loop, not `fillRange`, which reaches the element setter through a mixin
  // and so is not inlined
  for (var s = maxSymbolValue; s >= 0; s--) {
    counts[s] = 0;
  }

  final view = ByteData.sublistView(data);
  final accuracyLog = (data[start] & 0xf) + 5;
  if (accuracyLog > maxAccuracyLog) {
    _accuracyTooLarge(accuracyLog, maxAccuracyLog);
  }

  final tableSize = 1 << accuracyLog;
  // Plus one because a probability is encoded as its value minus one
  var remaining = tableSize + 1;
  var threshold = tableSize;
  var nbBits = accuracyLog + 1;
  var bitPos = 4;
  var symbol = 0;
  var previousWasZero = false;

  while (remaining > 1 && symbol <= maxSymbolValue) {
    if (previousWasZero) {
      var zeros = 0;
      var flag = 3;
      while (flag == 3) {
        flag = _peek(view, start, end, bitPos, 2);
        bitPos += 2;
        zeros += flag;
      }
      if (symbol + zeros > maxSymbolValue + 1) {
        _zeroRunRunsPast();
      }
      symbol += zeros;
      previousWasZero = false;
      if (symbol > maxSymbolValue) {
        break;
      }
    }

    // Small values cost one bit less, so the width depends on the value as well
    // as on the points left
    final max = (threshold << 1) - 1 - remaining;
    final low = _peek(view, start, end, bitPos, nbBits - 1);
    int value;
    if (low < max) {
      value = low;
      bitPos += nbBits - 1;
    } else {
      value = _peek(view, start, end, bitPos, nbBits);
      if (value >= threshold) {
        value -= max;
      }
      bitPos += nbBits;
    }

    final count = value - 1;
    remaining -= count < 0 ? -count : count;
    if (remaining < 0) {
      _probabilitiesOvershootTheTable();
    }
    counts[symbol] = count;
    symbol++;
    previousWasZero = count == 0;

    if (remaining < threshold) {
      if (remaining <= 1) {
        break;
      }
      nbBits = zstdHighestBit(remaining) + 1;
      threshold = 1 << (nbBits - 1);
    }
  }

  if (remaining != 1) {
    _probabilitiesDoNotAdd();
  }
  // `FSE_readNCount_body` has no lower bound on the symbol count: one symbol
  // taking the whole table is a description the reference reads

  final bytesRead = (bitPos + 7) >> 3;
  if (start + bytesRead > end) {
    _tableDescriptionIsTruncated();
  }
  return ZstdFseDistribution(counts, symbol - 1, accuracyLog, bytesRead);
}

/// [spread] and [nextState] are scratch, passed in so a decoder allocates them
/// once per frame rather than once per block
void buildFseTable(ZstdFseTable table, Int16List counts, int maxSymbol,
    int accuracyLog, Uint8List spread, Uint16List nextState) {
  final tableSize = 1 << accuracyLog;
  table.accuracyLog = accuracyLog;
  final rows = table.rows;

  final highBit = zstdHighBitTable;
  zstdSpreadSymbols(counts, maxSymbol, tableSize, spread, nextState);

  // Increasing state order visits each symbol's rows in the order the format
  // wants, so the running counter alone fixes width and baseline
  for (var state = 0; state < tableSize; state++) {
    final symbol = spread[state];
    final next = nextState[symbol];
    nextState[symbol] = next + 1;
    final nbBits = accuracyLog - highBit[next];
    rows[state] =
        symbol | (nbBits << 8) | (((next << nbBits) - tableSize) << 16);
  }
}

/// Forward little-endian. Bytes past [end] read as zero, a real overrun is
/// caught by the checks in [readFseDistribution]
@pragma('vm:prefer-inline')
int _peek(ByteData view, int start, int end, int bitPos, int count) {
  if (count == 0) {
    return 0;
  }
  final at = start + (bitPos >> 3);
  int window;
  if (at + 4 <= end) {
    window = view.getUint32(at, Endian.little);
  } else {
    window = 0;
    for (var i = 0; i < 4; i++) {
      final byte = at + i;
      if (byte < end) {
        window |= view.getUint8(byte) << (i << 3);
      }
    }
  }
  return (window >> (bitPos & 7)) & ((1 << count) - 1);
}

/// Places every symbol across the table's states, the format's own order:
/// probabilities of less than one take one row each from the end, retreating,
/// and each is a full state reset, then the rest fill the table by a fixed step
/// and skip what was taken
void zstdSpreadSymbols(Int16List counts, int maxSymbol, int tableSize,
    Uint8List spread, Uint16List nextState) {
  var highThreshold = tableSize - 1;
  for (var s = 0; s <= maxSymbol; s++) {
    final count = counts[s];
    if (count == -1) {
      spread[highThreshold] = s;
      highThreshold--;
      nextState[s] = 1;
    } else {
      nextState[s] = count;
    }
  }

  final step = (tableSize >> 1) + (tableSize >> 3) + 3;
  final mask = tableSize - 1;
  var position = 0;
  for (var s = 0; s <= maxSymbol; s++) {
    final count = counts[s];
    for (var i = 0; i < count; i++) {
      spread[position] = s;
      do {
        position = (position + step) & mask;
      } while (position > highThreshold);
    }
  }
  if (position != 0) {
    _tableSpreadDidNot();
  }
}

/// Every throw here lives out of line: inline, the exception's own
/// construction puts an allocation and a call into a function that is
/// otherwise straight-line work, and costs registers where nothing throws
@pragma('vm:never-inline')
Never _tableDescriptionIsEmpty() =>
    throw ZstdFseException('Table description is empty');

@pragma('vm:never-inline')
Never _zeroRunRunsPast() =>
    throw ZstdFseException('Zero run runs past the last symbol');

@pragma('vm:never-inline')
Never _probabilitiesOvershootTheTable() =>
    throw ZstdFseException('Probabilities overshoot the table size');

@pragma('vm:never-inline')
Never _probabilitiesDoNotAdd() =>
    throw ZstdFseException('Probabilities do not add up to the table size');

@pragma('vm:never-inline')
Never _tableDescriptionIsTruncated() =>
    throw ZstdFseException('Table description is truncated');

@pragma('vm:never-inline')
Never _tableSpreadDidNot() =>
    throw ZstdFseException('Table spread did not return to its start');

@pragma('vm:never-inline')
Never _accuracyTooLarge(int accuracyLog, int maxAccuracyLog) =>
    throw ZstdFseException(
        'Accuracy log $accuracyLog exceeds the $maxAccuracyLog allowed here');

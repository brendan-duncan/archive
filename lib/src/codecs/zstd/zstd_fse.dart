import 'dart:typed_data';

import 'zstd_error.dart';

// Finite State Entropy (tANS) tables, as described in RFC 8878 section 4.1.
// The same decoding table serves the Huffman weights and the three sequence
// fields. For the sequence fields it also carries the baseline and extra bit
// count of each state's code, so decoding a field takes one lookup.

const int zstdMaxLlCode = 35;
const int zstdMaxMlCode = 52;
const int zstdMaxOfCode = 31;
const int zstdLlMaxLog = 9;
const int zstdMlMaxLog = 9;
const int zstdOfMaxLog = 8;

const List<int> _llBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];

const List<int> _llBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];

const List<int> _mlBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
  4099, 8195, 16387, 32771, 65539,
];

const List<int> _mlBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
];

const List<int> _llDefaultNorm = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
  -1, -1, -1, -1,
];

const List<int> _mlDefaultNorm = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1, -1, -1,
];

const List<int> _ofDefaultNorm = [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
];

/// What a table decodes, which decides the baselines stored with each state.
enum ZstdFseKind { literalsLength, matchLength, offset, plain }

/// An FSE decoding table.
class ZstdFseTable {
  final ZstdFseKind kind;

  int accuracyLog = 0;

  /// The symbol each state decodes to.
  final Uint8List symbol;

  /// The number of bits read to move on from each state.
  final Uint8List nbBits;

  /// What those bits are added to, to give the next state.
  final Uint16List stateBase;

  /// For the sequence fields, the value of each state's code before its extra
  /// bits are added.
  final Uint32List baseValue;

  /// For the sequence fields, how many extra bits each state's code takes.
  final Uint8List extraBits;

  ZstdFseTable(this.kind, int maxLog)
      : symbol = Uint8List(1 << maxLog),
        nbBits = Uint8List(1 << maxLog),
        stateBase = Uint16List(1 << maxLog),
        baseValue = Uint32List(kind == ZstdFseKind.plain ? 0 : 1 << maxLog),
        extraBits = Uint8List(kind == ZstdFseKind.plain ? 0 : 1 << maxLog);

  int get _maxLog => symbol.length.bitLength - 1;

  int get _maxSymbol => switch (kind) {
        ZstdFseKind.literalsLength => zstdMaxLlCode,
        ZstdFseKind.matchLength => zstdMaxMlCode,
        ZstdFseKind.offset => zstdMaxOfCode,
        ZstdFseKind.plain => 255,
      };

  /// Builds the table for one of the predefined distributions.
  static ZstdFseTable predefined(ZstdFseKind kind) {
    final (norm, log) = switch (kind) {
      ZstdFseKind.literalsLength => (_llDefaultNorm, 6),
      ZstdFseKind.matchLength => (_mlDefaultNorm, 6),
      ZstdFseKind.offset => (_ofDefaultNorm, 5),
      ZstdFseKind.plain => throw ArgumentError.value(kind),
    };
    final table = ZstdFseTable(kind, log);
    table._build(Int16List.fromList(norm), norm.length, log);
    return table;
  }

  /// Makes this a table that always decodes [symbol] and reads no bits, for
  /// the RLE compression mode.
  void buildRle(int symbol) {
    if (symbol > _maxSymbol) {
      throw ZstdFormatError('RLE symbol $symbol out of range');
    }
    accuracyLog = 0;
    this.symbol[0] = symbol;
    nbBits[0] = 0;
    stateBase[0] = 0;
    _fillBaselines(1);
  }

  // Scratch space for the probabilities read from a description.
  static final Int16List _norm = Int16List(256);

  /// Reads a table description starting at [pos] and builds the table from
  /// it, returning the position of the first byte after the description.
  int readDescription(Uint8List src, int pos, int end) {
    if (pos >= end) {
      throw ZstdFormatError('Truncated FSE table description');
    }
    final maxSymbol = _maxSymbol;
    final norm = _norm;
    final endBit = end * 8;
    var bitPos = pos * 8;

    // Reads n bits, at most 16, from the forward little endian bitstream.
    // Bytes past the end read as zero; overrunning it is caught at the end.
    int read(int n) {
      final i = bitPos >> 3;
      var v = 0;
      if (i < end) {
        v = src[i];
        if (i + 1 < end) {
          v |= src[i + 1] << 8;
          if (i + 2 < end) {
            v |= src[i + 2] << 16;
          }
        }
      }
      final r = (v >> (bitPos & 7)) & ((1 << n) - 1);
      bitPos += n;
      return r;
    }

    final log = read(4) + 5;
    if (log > _maxLog) {
      throw ZstdFormatError('FSE accuracy log $log too large');
    }

    // [remaining] is one more than the probability points still to hand out,
    // which is what the field widths are worked out from.
    var remaining = (1 << log) + 1;
    var threshold = 1 << log;
    var bits = log + 1;
    var symbols = 0;
    var previousZero = false;

    while (remaining > 1 && symbols <= maxSymbol) {
      if (previousZero) {
        // A run of zero probabilities, two bits at a time.
        var run = symbols;
        for (;;) {
          final repeat = read(2);
          run += repeat;
          if (repeat != 3) {
            break;
          }
        }
        if (run > maxSymbol + 1) {
          throw ZstdFormatError('FSE table has too many symbols');
        }
        while (symbols < run) {
          norm[symbols++] = 0;
        }
        if (symbols > maxSymbol) {
          break;
        }
      }

      // Small values take one bit less.
      final max = (2 * threshold - 1) - remaining;
      final low = read(bits - 1);
      int count;
      if (low < max) {
        count = low;
      } else {
        count = low | (read(1) << (bits - 1));
        if (count >= threshold) {
          count -= max;
        }
      }
      // A count of zero stands for a probability below one, which still takes
      // one state.
      count--;
      remaining -= count < 0 ? -count : count;
      norm[symbols++] = count;
      previousZero = count == 0;

      if (remaining < threshold) {
        if (remaining <= 1) {
          break;
        }
        bits = remaining.bitLength;
        threshold = 1 << (bits - 1);
      }
    }

    if (remaining != 1 || bitPos > endBit) {
      throw ZstdFormatError('Corrupt FSE table description');
    }
    _build(norm, symbols, log);
    return (bitPos + 7) >> 3;
  }

  void _build(Int16List norm, int numSymbols, int log) {
    final size = 1 << log;
    final symbol = this.symbol;
    final nbBits = this.nbBits;
    final stateBase = this.stateBase;
    // The next state counter for each symbol, reused as it is consumed.
    final next = Uint16List(256);

    // Symbols with a probability below one each take a single state, from the
    // top of the table down.
    var high = size;
    for (var s = 0; s < numSymbols; s++) {
      if (norm[s] == -1) {
        symbol[--high] = s;
        next[s] = 1;
      }
    }

    // The rest are spread through the table, skipping the states taken above.
    final step = (size >> 1) + (size >> 3) + 3;
    final mask = size - 1;
    var pos = 0;
    for (var s = 0; s < numSymbols; s++) {
      final n = norm[s];
      if (n <= 0) {
        continue;
      }
      next[s] = n;
      for (var i = 0; i < n; i++) {
        symbol[pos] = s;
        do {
          pos = (pos + step) & mask;
        } while (pos >= high);
      }
    }
    if (pos != 0) {
      throw ZstdFormatError('Corrupt FSE distribution');
    }

    for (var i = 0; i < size; i++) {
      final n = next[symbol[i]]++;
      final b = log - (n.bitLength - 1);
      nbBits[i] = b;
      stateBase[i] = (n << b) - size;
    }

    accuracyLog = log;
    _fillBaselines(size);
  }

  void _fillBaselines(int size) {
    switch (kind) {
      case ZstdFseKind.literalsLength:
        for (var i = 0; i < size; i++) {
          final s = symbol[i];
          baseValue[i] = _llBase[s];
          extraBits[i] = _llBits[s];
        }
      case ZstdFseKind.matchLength:
        for (var i = 0; i < size; i++) {
          final s = symbol[i];
          baseValue[i] = _mlBase[s];
          extraBits[i] = _mlBits[s];
        }
      case ZstdFseKind.offset:
        for (var i = 0; i < size; i++) {
          final s = symbol[i];
          // Code 31 is written out: it is the sign bit wherever the shift
          // operators work on 32 bits.
          baseValue[i] = s == 31 ? 0x80000000 : 1 << s;
          extraBits[i] = s;
        }
      case ZstdFseKind.plain:
        break;
    }
  }
}

final ZstdFseTable zstdPredefinedLlTable =
    ZstdFseTable.predefined(ZstdFseKind.literalsLength);
final ZstdFseTable zstdPredefinedMlTable =
    ZstdFseTable.predefined(ZstdFseKind.matchLength);
final ZstdFseTable zstdPredefinedOfTable =
    ZstdFseTable.predefined(ZstdFseKind.offset);

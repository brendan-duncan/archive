import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_fse.dart';
import 'zstd_literals.dart';
import 'zstd_sequences_base.dart';
import 'zstd_window.dart';

/// Each symbol's baseline and extra bit count already in the places a row keeps
/// them, so a table build reads one entry instead of two and shifts nothing
final List<Uint64List> _values = [
  _packValues(zstdSlotLiteralsLength),
  _packValues(zstdSlotOffset),
  _packValues(zstdSlotMatchLength),
];

Uint64List _packValues(int slot) {
  final baselines = zstdSlotBaselines[slot];
  final extraBits = zstdSlotExtraBits[slot];
  final values = Uint64List(baselines.length);
  for (var i = 0; i < values.length; i++) {
    values[i] = (baselines[i] << 30) | (extraBits[i] << 24);
  }
  return values;
}

/// Decodes and executes the sequences of one block, holding the bitstream in a
/// 64 bit container.
///
/// One packed row per state holds the symbol's value as well as the
/// transition, so the loop needs no second dependent load: next state
/// including its table's base in bits 0 to 15, bits to read for it in 16 to 23,
/// the value's extra bits in 24 to 29, its baseline in 30 to 61. The top two
/// bits stay clear so every row is a Smi and no load allocates, and one array
/// for all three tables leaves the loop holding a single pointer
class ZstdSequences extends ZstdSequencesBase {
  /// Public so a test can check the packing against the specification
  final Uint64List rows = Uint64List(zstdSeqTableRows);

  ZstdSequences() {
    buildPredefinedTables();
  }

  @override
  int get minStreamBytes => 8;

  @override
  void buildTable(
      int base, int slot, Int16List counts, int maxSymbol, int accuracyLog) {
    final tableSize = 1 << accuracyLog;
    final values = _values[slot];
    final highBit = zstdHighBitTable;
    final rows = this.rows;
    zstdSpreadSymbols(counts, maxSymbol, tableSize, spread, nextState);

    for (var state = 0; state < tableSize; state++) {
      final symbol = spread[state];
      final next = nextState[symbol];
      nextState[symbol] = next + 1;
      final nbBits = accuracyLog - highBit[next];
      rows[base + state] = (base + (next << nbBits) - tableSize) |
          (nbBits << 16) |
          values[symbol];
    }
  }

  @override
  void setRleTable(int base, int slot, int symbol) {
    rows[base] = base | _values[slot][symbol];
  }

  @override
  int run(
      Uint8List src,
      ByteData view,
      int at,
      int length,
      ZstdLiterals literals,
      ZstdWindow window,
      Uint32List rep,
      int count,
      int blockSizeMax) {
    final rows = this.rows;

    final dstView = ByteData.sublistView(window.buffer);
    // Non zero once the buffer has been written through once, when a match may
    // reach back past its head into the pass before
    final lap = window.lap;
    final litLength = literals.length;
    final dstEnd = window.position + blockSizeMax;
    // The gap lets a copy overrun the output without reaching the
    // literals it has not read yet
    final litStart = dstEnd + zstdCopySlack;

    final last = src[at + length - 1];
    if (last == 0) {
      _zeroBitstream();
    }
    final int floor;
    final int limit;
    if (length >= 8) {
      floor = at;
      limit = 64;
    } else {
      floor = at + length - 8;
      limit = length << 3;
    }
    var position = at + length - 8;
    var container = view.getUint64(position, Endian.little);
    var consumed = 8 - zstdHighestBit(last);

    final llLog = logs[zstdSlotLiteralsLength];
    final ofLog = logs[zstdSlotOffset];
    final mlLog = logs[zstdSlotMatchLength];
    var llState = bases[zstdSlotLiteralsLength] +
        ((container << consumed) >>> 1 >>> (63 - llLog));
    consumed += llLog;
    var ofState = bases[zstdSlotOffset] +
        ((container << consumed) >>> 1 >>> (63 - ofLog));
    consumed += ofLog;
    var mlState = bases[zstdSlotMatchLength] +
        ((container << consumed) >>> 1 >>> (63 - mlLog));
    consumed += mlLog;

    // `STREAM_ACCUMULATOR_MIN_64` less what the three state reads may take
    final refillAt = 57 - (llLog + mlLog + ofLog);

    var rep0 = rep[0];
    var rep1 = rep[1];
    var rep2 = rep[2];
    var out = window.position;
    var litAt = litStart;

    for (var i = count; i > 0; i--) {
      var step = consumed >> 3;
      if (position - step < floor) {
        consumed -= (position - floor) << 3;
        position = floor;
      } else {
        position -= step;
        consumed &= 7;
      }
      container = view.getUint64(position, Endian.little);

      final ofRow = rows[ofState];
      final mlRow = rows[mlState];
      final llRow = rows[llState];

      final ofBits = (ofRow << 34) >>> 58;
      final offsetValue =
          (ofRow >> 30) + ((container << consumed) >>> 1 >>> (63 - ofBits));
      consumed += ofBits;
      final mlBits = (mlRow << 34) >>> 58;
      final matchLength =
          (mlRow >> 30) + ((container << consumed) >>> 1 >>> (63 - mlBits));
      consumed += mlBits;

      // `ZSTD_decodeSequence`: the container holds fifty seven bits after a
      // fill, so what is left over covers the literal length and the three
      // state reads unless this sequence's own fields are unusually wide
      final llBits = (llRow << 34) >>> 58;
      if (ofBits + mlBits + llBits >= refillAt) {
        step = consumed >> 3;
        if (position - step < floor) {
          consumed -= (position - floor) << 3;
          position = floor;
        } else {
          position -= step;
          consumed &= 7;
        }
        container = view.getUint64(position, Endian.little);
      }
      final literalsLength =
          (llRow >> 30) + ((container << consumed) >>> 1 >>> (63 - llBits));
      consumed += llBits;

      if (i != 1) {
        final llNbBits = (llRow << 40) >>> 56;
        llState = ((llRow << 48) >>> 48) +
            ((container << consumed) >>> 1 >>> (63 - llNbBits));
        consumed += llNbBits;
        final mlNbBits = (mlRow << 40) >>> 56;
        mlState = ((mlRow << 48) >>> 48) +
            ((container << consumed) >>> 1 >>> (63 - mlNbBits));
        consumed += mlNbBits;
        final ofNbBits = (ofRow << 40) >>> 56;
        ofState = ((ofRow << 48) >>> 48) +
            ((container << consumed) >>> 1 >>> (63 - ofNbBits));
        consumed += ofNbBits;
      }

      final int offset;
      if (offsetValue > 3) {
        offset = offsetValue - 3;
        rep2 = rep1;
        rep1 = rep0;
        rep0 = offset;
      } else {
        final slot = literalsLength == 0 ? offsetValue + 1 : offsetValue;
        if (slot == 1) {
          offset = rep0;
        } else if (slot == 2) {
          offset = rep1;
          rep1 = rep0;
          rep0 = offset;
        } else if (slot == 3) {
          offset = rep2;
          rep2 = rep1;
          rep1 = rep0;
          rep0 = offset;
        } else {
          offset = rep0 - 1;
          if (offset == 0) {
            _repeatUnderflows();
          }
          rep2 = rep1;
          rep1 = rep0;
          rep0 = offset;
        }
      }

      if (out + literalsLength + matchLength > dstEnd) {
        _ranPastBlock();
      }

      // Most literal runs are under eight bytes and nearly all under sixteen,
      // so the common lengths cost stores and no loop at all
      dstView.setUint64(
          out, dstView.getUint64(litAt, Endian.little), Endian.little);
      if (literalsLength > 8) {
        dstView.setUint64(out + 8, dstView.getUint64(litAt + 8, Endian.little),
            Endian.little);
        if (literalsLength > 16) {
          var to = out + 16;
          var read = litAt + 16;
          var take = literalsLength - 16;
          do {
            dstView.setUint64(
                to, dstView.getUint64(read, Endian.little), Endian.little);
            to += 8;
            read += 8;
            take -= 8;
          } while (take > 0);
        }
      }
      litAt += literalsLength;
      out += literalsLength;

      var from = out - offset;
      if (from < 0) {
        // The buffer has been written through once and this match reaches into
        // the pass before, which sits where it was left rather than having been
        // moved down
        from += lap;
        if (lap == 0 || from <= out) {
          _offsetBeforeStart(offset);
        }
        out = _wrapped(window.buffer, out, from, matchLength, lap);
        continue;
      }
      if (offset >= 8) {
        dstView.setUint64(
            out, dstView.getUint64(from, Endian.little), Endian.little);
        dstView.setUint64(
            out + 8, dstView.getUint64(from + 8, Endian.little), Endian.little);
        // Matches run to thirty two bytes in 98% of sequences, so those cost a
        // second pair of stores and no loop. What is left goes thirty two bytes
        // an iteration the way `ZSTD_wildcopy` does. Either may write past the
        // match. `zstdCopySlack` is there for that, and the stores stay in
        // program order so a short offset still repeats the way it should
        if (matchLength > 16) {
          dstView.setUint64(out + 16,
              dstView.getUint64(from + 16, Endian.little), Endian.little);
          dstView.setUint64(out + 24,
              dstView.getUint64(from + 24, Endian.little), Endian.little);
          if (matchLength > 32) {
            var to = out + 32;
            var read = from + 32;
            var left = matchLength - 32;
            do {
              dstView.setUint64(
                  to, dstView.getUint64(read, Endian.little), Endian.little);
              dstView.setUint64(to + 8,
                  dstView.getUint64(read + 8, Endian.little), Endian.little);
              dstView.setUint64(to + 16,
                  dstView.getUint64(read + 16, Endian.little), Endian.little);
              dstView.setUint64(to + 24,
                  dstView.getUint64(read + 24, Endian.little), Endian.little);
              to += 32;
              read += 32;
              left -= 32;
            } while (left > 0);
          }
        }
        out += matchLength;
      } else {
        final stop = out + matchLength;
        while (out < stop) {
          dstView.setUint8(out++, dstView.getUint8(from++));
        }
      }
    }

    if (out > dstEnd || litAt > litStart + litLength) {
      _ranPastBlock();
    }
    if (position != floor || consumed != limit) {
      _notFullyConsumed();
    }

    final rest = litStart + litLength - litAt;
    if (out + rest > dstEnd) {
      _outputTooLarge();
    }
    window.buffer.setRange(out, out + rest, window.buffer, litAt);
    out += rest;

    rep[0] = rep0;
    rep[1] = rep1;
    rep[2] = rep2;
    return out;
  }
}

/// Copies a match whose source is on the pass before this one. It may run to
/// the end of the buffer and go on at its head, where this pass began
int _wrapped(Uint8List dst, int out, int from, int length, int lap) {
  var left = length;
  var read = from;
  while (left > 0) {
    final run = lap - read < left ? lap - read : left;
    for (var i = 0; i < run; i++) {
      dst[out + i] = dst[read + i];
    }
    out += run;
    read += run;
    left -= run;
    if (read == lap) {
      read = 0;
    }
  }
  return out;
}

/// Every throw of the sequence loop is moved out of line. Left inline, the
/// exception's construction and its message's interpolation put an allocation,
/// a call and the boxing of their operands in the loop body, which costs
/// registers on the path that never throws
@pragma('vm:never-inline')
Never _zeroBitstream() =>
    throw ZstdSequencesException('Bitstream ends in a zero byte');

@pragma('vm:never-inline')
Never _repeatUnderflows() =>
    throw ZstdSequencesException('Repeat offset underflows');

@pragma('vm:never-inline')
Never _offsetBeforeStart(int offset) => throw ZstdSequencesException(
    'Match offset $offset reaches before the start of the output');

@pragma('vm:never-inline')
Never _ranPastBlock() =>
    throw ZstdSequencesException('Sequences ran past the block');

@pragma('vm:never-inline')
Never _notFullyConsumed() =>
    throw ZstdSequencesException('Sequence bitstream was not fully consumed');

@pragma('vm:never-inline')
Never _outputTooLarge() =>
    throw ZstdSequencesException('Block output is larger than a block');

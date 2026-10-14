import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_fse.dart';
import 'zstd_literals.dart';
import 'zstd_sequences_base.dart';
import 'zstd_window.dart';

/// Decodes and executes the sequences of one block, holding the bitstream in a
/// 32 bit container.
///
/// The native form packs a whole row into one 64 bit integer. An int is a
/// JavaScript number here and cannot hold that, so the four fields sit in
/// four arrays and the loop pays four loads. A 32 bit container also holds too
/// few bits to serve a read of more than 24, so it is refilled between fields
class ZstdSequences extends ZstdSequencesBase {
  /// Public so a test can check the packing against the specification
  final Uint16List next = Uint16List(zstdSeqTableRows);
  final Uint8List nbBits = Uint8List(zstdSeqTableRows);
  final Uint8List extraBits = Uint8List(zstdSeqTableRows);
  final Uint32List baseline = Uint32List(zstdSeqTableRows);

  ZstdSequences() {
    buildPredefinedTables();
  }

  @override
  int get minStreamBytes => 4;

  @override
  void buildTable(
      int base, int slot, Int16List counts, int maxSymbol, int accuracyLog) {
    final tableSize = 1 << accuracyLog;
    final baselines = zstdSlotBaselines[slot];
    final extras = zstdSlotExtraBits[slot];
    final highBit = zstdHighBitTable;
    zstdSpreadSymbols(counts, maxSymbol, tableSize, spread, nextState);

    for (var state = 0; state < tableSize; state++) {
      final symbol = spread[state];
      final step = nextState[symbol];
      nextState[symbol] = step + 1;
      final width = accuracyLog - highBit[step];
      final row = base + state;
      next[row] = base + (step << width) - tableSize;
      nbBits[row] = width;
      extraBits[row] = extras[symbol];
      baseline[row] = baselines[symbol];
    }
  }

  @override
  void setRleTable(int base, int slot, int symbol) {
    next[base] = base;
    nbBits[base] = 0;
    extraBits[base] = zstdSlotExtraBits[slot][symbol];
    baseline[base] = zstdSlotBaselines[slot][symbol];
  }

  int _position = 0;
  int _consumed = 0;
  int _container = 0;
  int _floor = 0;
  ByteData _view = ByteData(0);

  /// Moves back to where the bits still to read start, so the next read of up
  /// to 24 bits is in the container
  void _reload() {
    final step = _consumed >> 3;
    if (_position - step < _floor) {
      _consumed -= (_position - _floor) << 3;
      _position = _floor;
    } else {
      _position -= step;
      _consumed &= 7;
    }
    _container = _view.getUint32(_position, Endian.little);
  }

  /// [count] in 0 to 24, with at least that many bits in the container
  int _take(int count) {
    if (count == 0) {
      return 0;
    }
    final value = (_container << _consumed) >>> (32 - count);
    _consumed += count;
    return value;
  }

  /// Offset codes reach 31 bits, more than a 32 bit container can hold at an
  /// arbitrary bit offset, so those are read in two halves
  int _takeWide(int count) {
    if (count <= 24) {
      return _take(count);
    }
    final high = _take(count - 24);
    _reload();
    return high * 16777216 + _take(24);
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
    final next = this.next;
    final nbBits = this.nbBits;
    final extraBits = this.extraBits;
    final baseline = this.baseline;

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
      throw ZstdSequencesException('Bitstream ends in a zero byte');
    }
    final int limit;
    if (length >= 4) {
      _floor = at;
      limit = 32;
    } else {
      _floor = at + length - 4;
      limit = length << 3;
    }
    _view = view;
    _position = at + length - 4;
    _container = view.getUint32(_position, Endian.little);
    _consumed = 8 - zstdHighestBit(last);

    var llState =
        bases[zstdSlotLiteralsLength] + _take(logs[zstdSlotLiteralsLength]);
    _reload();
    var ofState = bases[zstdSlotOffset] + _take(logs[zstdSlotOffset]);
    _reload();
    var mlState = bases[zstdSlotMatchLength] + _take(logs[zstdSlotMatchLength]);

    var rep0 = rep[0];
    var rep1 = rep[1];
    var rep2 = rep[2];
    var out = window.position;
    var litAt = litStart;

    for (var i = count; i > 0; i--) {
      _reload();
      final offsetValue = baseline[ofState] + _takeWide(extraBits[ofState]);
      _reload();
      final matchLength = baseline[mlState] + _take(extraBits[mlState]);
      _reload();
      final literalsLength = baseline[llState] + _take(extraBits[llState]);

      if (i != 1) {
        // The three widths add to 26, which does not fit above whatever the
        // last refill left consumed, so each takes its own
        _reload();
        llState = next[llState] + _take(nbBits[llState]);
        _reload();
        mlState = next[mlState] + _take(nbBits[mlState]);
        _reload();
        ofState = next[ofState] + _take(nbBits[ofState]);
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
            throw ZstdSequencesException('Repeat offset underflows');
          }
          rep2 = rep1;
          rep1 = rep0;
          rep0 = offset;
        }
      }

      if (out + literalsLength + matchLength > dstEnd) {
        throw ZstdSequencesException('Sequences ran past the block');
      }
      _copy(dstView, out, litAt, literalsLength);
      litAt += literalsLength;
      out += literalsLength;

      var from = out - offset;
      if (from < 0) {
        // The buffer has been written through once and this match reaches into
        // the pass before, which sits where it was left rather than having been
        // moved down
        from += lap;
        if (lap == 0 || from <= out) {
          throw ZstdSequencesException(
              'Match offset $offset reaches before the '
              'start of the output');
        }
        out = _wrapped(window.buffer, out, from, matchLength, lap);
        continue;
      }
      if (offset >= 8) {
        _copy(dstView, out, from, matchLength);
        out += matchLength;
      } else {
        final stop = out + matchLength;
        while (out < stop) {
          dstView.setUint8(out++, dstView.getUint8(from++));
        }
      }
    }

    if (out > dstEnd || litAt > litStart + litLength) {
      throw ZstdSequencesException('Sequences ran past the block');
    }
    if (_position != _floor || _consumed != limit) {
      throw ZstdSequencesException('Sequence bitstream was not fully consumed');
    }

    final rest = litStart + litLength - litAt;
    if (out + rest > dstEnd) {
      throw ZstdSequencesException('Block output is larger than a block');
    }
    window.buffer.setRange(out, out + rest, window.buffer, litAt);
    out += rest;

    rep[0] = rep0;
    rep[1] = rep1;
    rep[2] = rep2;
    return out;
  }

  /// A match that reaches across the head of the ring, taken a run at a time so
  /// the two pieces are copied where they are rather than moved together first
  static int _wrapped(Uint8List dst, int out, int from, int length, int lap) {
    var left = length;
    var read = from;
    var at = out;
    while (left > 0) {
      final run = lap - read < left ? lap - read : left;
      for (var i = 0; i < run; i++) {
        dst[at + i] = dst[read + i];
      }
      at += run;
      read += run;
      left -= run;
      if (read == lap) {
        read = 0;
      }
    }
    return at;
  }

  /// Writes at least eight bytes and rounds up, which the slack after the
  /// block's output and after its literals is there to absorb
  static void _copy(ByteData dst, int to, int from, int length) {
    var at = to;
    var read = from;
    var left = length;
    do {
      dst.setUint32(at, dst.getUint32(read, Endian.little), Endian.little);
      dst.setUint32(
          at + 4, dst.getUint32(read + 4, Endian.little), Endian.little);
      at += 8;
      read += 8;
      left -= 8;
    } while (left > 0);
  }
}

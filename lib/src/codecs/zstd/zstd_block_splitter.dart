import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_level_params.dart';

const _knuth = 0x9e3779b9;
const _chunk = 8 * 1024;
const _segment = 512;
const _penaltyRate = 16;
const _thresholdBase = _penaltyRate - 2;
const _startingPenalty = 3;

/// Sampling rate and hash width per split level, `records_fs` and `hashParams`
const _rates = [43, 11, 5, 1];
const _hashLogs = [8, 9, 10, 10];

/// How hard each strategy looks for a boundary, `splitLevels` indexed the way
/// our strategy constants run. Zero compares the block's two ends, the rest
/// scan it in chunks at the sampling rate one below. Our lazy covers the
/// reference's lazy and lazy2, which it separates by depth
const _splitLevels = [0, 1, 2, 2, 3, 4];
const _lazy2SplitLevel = 3;

/// Where a block is better cut short, from the distribution of short hashes
/// in one part against another. A block that reads as one kind of data
/// throughout is left whole
class ZstdBlockSplitter {
  final Uint32List _past = Uint32List(1 << 10);
  final Uint32List _fresh = Uint32List(1 << 10);
  final Uint32List _middle = Uint32List(1 << 10);
  int _pastEvents = 0;
  int _freshEvents = 0;

  /// How many bytes the next block should cover, at most [blockSizeMax].
  /// [savings] is the total saved by every block so far, which keeps the
  /// splitter away from data that does not compress
  int sizeFor(Uint8List src, int at, int left, int blockSizeMax,
      ZstdLevelParams params, int savings) {
    final whole = left < blockSizeMax ? left : blockSizeMax;
    if (whole < zstdBlockMaximumSize || savings < 3) {
      return whole;
    }
    var level = _splitLevels[params.strategy];
    if (params.strategy == zstdStrategyLazy && params.depth > 1) {
      level = _lazy2SplitLevel;
    }
    return level == 0
        ? _fromBorders(src, at, whole)
        : _byChunks(src, at, whole, level - 1);
  }

  /// Compares the first and last segments, then splits at a quarter, a half or
  /// three quarters depending on which end the middle resembles
  int _fromBorders(Uint8List src, int at, int size) {
    _count(src, at, _segment, _past, 1, 8);
    _pastEvents = _segment;
    _count(src, at + size - _segment, _segment, _fresh, 1, 8);
    _freshEvents = _segment;
    if (!_differ(0, 8)) {
      return size;
    }
    _count(src, at + (size >> 1) - (_segment >> 1), _segment, _middle, 1, 8);
    final fromBegin = _distance(_past, _pastEvents, _middle, _segment, 8);
    final fromEnd = _distance(_fresh, _freshEvents, _middle, _segment, 8);
    final apart = fromBegin - fromEnd;
    if ((apart < 0 ? -apart : apart) < _segment * _segment ~/ 3) {
      return size >> 1;
    }
    return fromBegin > fromEnd ? size >> 2 : size - (size >> 2);
  }

  /// Scans the block eight kilobytes at a time and stops at the first chunk
  /// that does not look like everything before it
  int _byChunks(Uint8List src, int at, int size, int level) {
    final rate = _rates[level];
    final hashLog = _hashLogs[level];
    var penalty = _startingPenalty;
    _count(src, at, _chunk - 1, _past, rate, hashLog);
    _pastEvents = (_chunk - 1) ~/ rate;
    for (var pos = _chunk; pos <= size - _chunk; pos += _chunk) {
      _count(src, at + pos, _chunk - 1, _fresh, rate, hashLog);
      _freshEvents = (_chunk - 1) ~/ rate;
      if (_differ(penalty, hashLog)) {
        return pos;
      }
      for (var i = 0; i < 1 << hashLog; i++) {
        _past[i] += _fresh[i];
      }
      _pastEvents += _freshEvents;
      if (penalty > 0) {
        penalty--;
      }
    }
    return size;
  }

  /// Counts [limit] positions starting at [at], one every [rate] bytes
  void _count(Uint8List src, int at, int limit, Uint32List into, int rate,
      int hashLog) {
    into.fillRange(0, 1 << hashLog, 0);
    if (hashLog == 8) {
      for (var n = 0; n < limit; n += rate) {
        into[src[at + n]]++;
      }
      return;
    }
    final shift = 32 - hashLog;
    for (var n = 0; n < limit; n += rate) {
      final pair = src[at + n] | (src[at + n + 1] << 8);
      into[((pair * _knuth) & 0xffffffff) >>> shift]++;
    }
  }

  bool _differ(int penalty, int hashLog) {
    final deviation =
        _distance(_past, _pastEvents, _fresh, _freshEvents, hashLog);
    final threshold =
        _pastEvents * _freshEvents * (_thresholdBase + penalty) ~/ _penaltyRate;
    return deviation >= threshold;
  }

  /// The two distributions scaled to a common total, summed term by term
  int _distance(
      Uint32List a, int aEvents, Uint32List b, int bEvents, int hashLog) {
    var distance = 0;
    for (var n = 0; n < 1 << hashLog; n++) {
      final term = a[n] * bEvents - b[n] * aEvents;
      distance += term < 0 ? -term : term;
    }
    return distance;
  }
}

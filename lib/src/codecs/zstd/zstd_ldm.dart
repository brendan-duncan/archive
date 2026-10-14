import 'dart:typed_data';

import '../../util/xxh64.dart';
import 'zstd_ldm_geartab.dart';
import 'zstd_web.dart';

/// `LDM_BATCH_SIZE`, how many split points one pass of the rolling hash
/// collects before they are looked up
const _batch = 64;

const _bucketLogMin = 4;
const _bucketLogMax = 8;
const _hashLogMin = 6;
const _hashLogMax = 30;
const _minMatchBase = 64;

/// `ZSTD_strategy` as the reference numbers it, one to nine.
/// [ZstdLevelParams.refStrategy] holds that number. The six strategies of the
/// parse are not these
const _btopt = 7;
const _btultra = 8;

/// The matches one block's long distance search found, in the order they cover
/// the block. `RawSeqStore_t`
class ZstdLdmSequences {
  final Uint32List litLength;
  final Uint32List matchLength;
  final Uint32List offset;
  int size = 0;

  /// `RawSeqStore_t.pos` and `posInSequence`: where a reader of this store has
  /// got to. A store generated for one block is read whole and the cursor never
  /// moves off zero; one generated for a whole job is read a block at a time
  int pos = 0;
  int inSequence = 0;

  ZstdLdmSequences(int capacity)
      : litLength = Uint32List(capacity),
        matchLength = Uint32List(capacity),
        offset = Uint32List(capacity);

  void reset() {
    size = 0;
    pos = 0;
    inSequence = 0;
  }

  /// `ZSTD_ldm_skipRawSeqStoreBytes`: moves the cursor past [bytes] of the
  /// input the store covers. A block leaves that much behind it
  void skipBytes(int bytes) {
    var at = inSequence + bytes;
    while (at != 0 && pos < size) {
      final span = litLength[pos] + matchLength[pos];
      if (at >= span) {
        at -= span;
        pos++;
      } else {
        inSequence = at;
        return;
      }
    }
    inSequence = 0;
  }
}

/// How far the optimal parse plans, `ZSTD_OPT_NUM`
const _optMax = 1 << 12;

/// A position past the end of any block, which parks the cursor for the rest
/// of one when it has nothing more to offer
const _never = 0xffffffff;

/// The cursor the optimal parse keeps over a block's long distance matches. It
/// offers them as candidates rather than taking them. `ZSTD_optLdm_t`
class ZstdOptLdm {
  ZstdLdmSequences? _store;
  int _pos = 0;
  int _inSequence = 0;
  int _start = 0;
  int _end = 0;
  int _offset = 0;

  /// Points the cursor at a block's matches, which each pass over the block
  /// reads from the beginning. The reference takes its first match here rather
  /// than on the first candidate, which moves the cursor one sequence on before
  /// the parse starts and so keeps a block's last match out of the parse
  void begin(ZstdLdmSequences? store, int size) {
    _store = store;
    // The reference copies the store by value, cursor and all, so a parse over
    // one block of a job's store starts where the block before it stopped and
    // leaves the store itself alone
    _pos = store?.pos ?? 0;
    _inSequence = store?.inSequence ?? 0;
    _start = 0;
    _end = 0;
    _offset = 0;
    if (store != null) {
      _take(store, 0, size);
    }
  }

  /// `ZSTD_optLdm_processMatchCandidate`: adds the match covering [at], when
  /// there is one and it is long enough. Returns the new candidate count
  int process(Uint32List lengths, Uint32List offBases, int count, int at,
      int remaining, int minMatch) {
    final store = _store;
    if (store == null || store.size == 0 || _pos >= store.size) {
      return count;
    }
    if (at >= _end) {
      // The parse steps over a match rather than landing on its end
      if (at > _end) {
        _skip(store, at - _end);
      }
      _take(store, at, remaining);
    }
    if (at < _start || at >= _end) {
      return count;
    }
    final length = _end - at;
    if (length < minMatch) {
      return count;
    }
    if (count == 0 || (length > lengths[count - 1] && count < _optMax)) {
      lengths[count] = length;
      offBases[count] = _offset + 3;
      count++;
    }
    return count;
  }

  /// `ZSTD_opt_getNextMatchAndUpdateSeqStore`
  void _take(ZstdLdmSequences store, int at, int remaining) {
    if (_pos >= store.size) {
      _start = _never;
      _end = _never;
      return;
    }
    final litLength = store.litLength[_pos];
    final matchLength = store.matchLength[_pos];
    final blockEnd = at + remaining;
    final litLeft = _inSequence < litLength ? litLength - _inSequence : 0;
    final matchLeft =
        litLeft == 0 ? matchLength - (_inSequence - litLength) : matchLength;
    if (litLeft >= remaining) {
      _start = _never;
      _end = _never;
      _skip(store, remaining);
      return;
    }
    _start = at + litLeft;
    _end = _start + matchLeft;
    _offset = store.offset[_pos];
    if (_end > blockEnd) {
      _end = blockEnd;
      _skip(store, blockEnd - at);
    } else {
      _skip(store, litLeft + matchLeft);
    }
  }

  /// `ZSTD_optLdm_skipRawSeqStoreBytes`
  void _skip(ZstdLdmSequences store, int bytes) {
    var at = _inSequence + bytes;
    while (at != 0 && _pos < store.size) {
      final span = store.litLength[_pos] + store.matchLength[_pos];
      if (at >= span) {
        at -= span;
        _pos++;
      } else {
        _inSequence = at;
        break;
      }
    }
    if (at == 0 || _pos == store.size) {
      _inSequence = 0;
    }
  }
}

/// Matches far enough back that the level's own tables cannot reach them, found
/// by hashing every position where a rolling hash of the last [minMatch] bytes
/// matches a mask. `zstd_ldm.c`
class ZstdLdm {
  final int minMatch;
  final int bucketLog;
  final int hashBits;
  final int windowLog;

  /// A bucket of entries per hash, each a position raised by one so that zero
  /// means a slot never filled, beside the top half of its full hash
  final Uint32List _entryPos;
  final Uint32List _entrySum;

  /// Where the next insertion of each bucket goes
  final Uint8List _next;

  final Uint64List? _gear = zstdUse64Bit ? zstdLdmGearTab : null;
  final Xxh64 _xxh = Xxh64();
  final Int32List _splits = Int32List(_batch);
  final Int32List _splitHash = Int32List(_batch);
  final Uint32List _splitSum = Uint32List(_batch);
  int _found = 0;

  /// The mask a rolling hash must match for a position to be hashed, and the
  /// state kept between passes
  final int _stopMask;
  int _stopMaskHigh = 0;
  int _rolling = 0;
  int _rollingHigh = 0;

  /// `window.dictLimit` in the reference's index space, a file position raised
  /// by one. Nothing at or below it may be matched
  int _dictLimit = 1;

  ZstdLdm(this.minMatch, this.bucketLog, this.hashBits, this.windowLog,
      this._stopMask)
      : _entryPos = Uint32List(1 << (hashBits + bucketLog)),
        _entrySum = Uint32List(1 << (hashBits + bucketLog)),
        _next = Uint8List(1 << hashBits);

  /// `ZSTD_resolveEnableLdm` and `ZSTD_ldm_adjustParameters`, which only the
  /// widest window of the hardest searching levels turns on
  static ZstdLdm? forParams(int strategy, int windowLog) {
    if (strategy < _btopt || windowLog < 27) {
      return null;
    }
    final rateLog = 7 - strategy ~/ 3;
    var hashLog = windowLog - rateLog;
    if (hashLog < _hashLogMin) {
      hashLog = _hashLogMin;
    } else if (hashLog > _hashLogMax) {
      hashLog = _hashLogMax;
    }
    final minMatch = strategy >= _btultra ? _minMatchBase ~/ 2 : _minMatchBase;
    var bucketLog = strategy < _bucketLogMin
        ? _bucketLogMin
        : (strategy > _bucketLogMax ? _bucketLogMax : strategy);
    if (bucketLog > hashLog) {
      bucketLog = hashLog;
    }
    final ldm = ZstdLdm(minMatch, bucketLog, hashLog - bucketLog, windowLog,
        _stopMaskFor(minMatch, rateLog));
    if (!zstdUse64Bit) ldm._stopMaskHigh = _webMask(minMatch, rateLog, 32);
    return ldm;
  }

  /// `ZSTD_ldm_gear_init`: the mask takes the bits the rolling hash gives the
  /// most weight to, so a split point depends on a whole match's worth of bytes
  static int _stopMaskFor(int minMatch, int rateLog) {
    if (!zstdUse64Bit) return _webMask(minMatch, rateLog, 0);
    final width = minMatch < 64 ? minMatch : 64;
    if (rateLog > 0 && rateLog <= width) {
      return ((1 << rateLog) - 1) << (width - rateLog);
    }
    return (1 << rateLog) - 1;
  }

  int capacityFor(int blockSize) => blockSize ~/ minMatch + 1;

  /// The buffer moved [delta] bytes down. A bucket is keyed on the bytes, not
  /// on a position, so only the positions it holds move
  void slide(int delta) {
    for (var at = 0; at < _entryPos.length; at++) {
      final held = _entryPos[at];
      _entryPos[at] = held <= delta ? 0 : held - delta;
    }
    _dictLimit = _dictLimit > delta + 1 ? _dictLimit - delta : 1;
  }

  /// `ZSTD_ldm_fillHashTable`: a dictionary's split points, registered without
  /// looking for a match, so the first block can reach into it
  void fill(Uint8List src, int start, int end) {
    final hashMask = (1 << hashBits) - 1;
    var ip = start;
    _rolling = 0xffffffff;
    if (!zstdUse64Bit) _rollingHigh = 0;
    while (ip < end) {
      final hashed = _feed(src, ip, end - ip);
      for (var n = 0; n < _found; n++) {
        if (ip + _splits[n] < start + minMatch) {
          continue;
        }
        final split = ip + _splits[n] - minMatch;
        _xxh.reset();
        _xxh.update(src, split, minMatch);
        _insert(_xxh.digestLow & hashMask, _xxh.digestHigh, split);
      }
      ip += hashed;
    }
  }

  /// `ZSTD_ldm_generateSequences`. One block is always one chunk, since a block
  /// never reaches the reference's chunk size of a megabyte
  void generate(
      Uint8List src, ByteData view, int start, int end, ZstdLdmSequences out) {
    out.reset();
    // `ZSTD_ldm_generateSequences` processes a megabyte at a time, bounding the
    // window at each chunk's end rather than once over the whole span. A block
    // never reaches that, a threaded job does
    const chunkMax = 1 << 20;
    final capacity = out.litLength.length;
    var leftover = 0;
    var at = start;
    while (at < end && out.size < capacity) {
      final chunkEnd = end - at < chunkMax ? end : at + chunkMax;
      final low = chunkEnd + 1 - (1 << windowLog);
      if (low > _dictLimit) {
        _dictLimit = low;
      }
      final before = out.size;
      final rest = chunkEnd - at < minMatch
          ? chunkEnd - at
          : _generate(src, view, at, chunkEnd, out);
      // The literals a chunk ends on belong to the first sequence of the next
      // one, which started measuring from its own beginning
      if (before < out.size) {
        out.litLength[before] += leftover;
        leftover = rest;
      } else {
        leftover += chunkEnd - at;
      }
      at = chunkEnd;
    }
  }

  /// Returns the literals left over after the last match it found.
  /// `ZSTD_ldm_generateSequences_internal` reports the same
  int _generate(
      Uint8List src, ByteData view, int start, int end, ZstdLdmSequences out) {
    final capacity = out.litLength.length;
    final limit = end - 8;
    final floor = _dictLimit - 1;
    final width = 1 << bucketLog;
    final hashMask = (1 << hashBits) - 1;
    var anchor = start;
    // `ZSTD_ldm_gear_reset` leaves the state alone, so the first bytes of a
    // block are stepped over rather than hashed
    var ip = start + minMatch;
    _rolling = 0xffffffff;
    if (!zstdUse64Bit) _rollingHigh = 0;

    while (ip < limit) {
      final hashed = _feed(src, ip, limit - ip);
      final found = _found;
      for (var n = 0; n < found; n++) {
        final split = ip + _splits[n] - minMatch;
        _xxh.reset();
        _xxh.update(src, split, minMatch);
        _splits[n] = split;
        _splitHash[n] = _xxh.digestLow & hashMask;
        _splitSum[n] = _xxh.digestHigh;
      }

      for (var n = 0; n < found; n++) {
        final split = _splits[n];
        final hash = _splitHash[n];
        final sum = _splitSum[n];
        if (split < anchor) {
          _insert(hash, sum, split);
          continue;
        }
        var best = 0;
        var forward = 0;
        var backward = 0;
        var bestPos = -1;
        final bucket = hash << bucketLog;
        for (var i = 0; i < width; i++) {
          final held = _entryPos[bucket + i];
          if (_entrySum[bucket + i] != sum || held <= _dictLimit) {
            continue;
          }
          final match = held - 1;
          final ahead = _count(src, view, split, match, end);
          if (ahead < minMatch) {
            continue;
          }
          final behind = _countBack(src, split, anchor, match, floor);
          if (ahead + behind > best) {
            best = ahead + behind;
            forward = ahead;
            backward = behind;
            bestPos = match;
          }
        }
        if (bestPos < 0) {
          _insert(hash, sum, split);
          continue;
        }
        final at = out.size;
        if (at == capacity) {
          return end - anchor < 0 ? 0 : end - anchor;
        }
        out.litLength[at] = split - backward - anchor;
        out.matchLength[at] = forward + backward;
        out.offset[at] = split - bestPos;
        out.size = at + 1;
        _insert(hash, sum, split);
        anchor = split + forward;
        // A match reaching past what this pass hashed is a repeating pattern,
        // and every later repetition would land on the mask the same way, so
        // only the first is worth a table entry
        if (anchor > ip + hashed) {
          ip = anchor - hashed;
          break;
        }
      }
      ip += hashed;
    }
    return end - anchor < 0 ? 0 : end - anchor;
  }

  /// `ZSTD_ldm_gear_feed`: records where the hash matches the mask, and stops
  /// once a batch is full. Returns how many bytes it read
  static int _webMask(int minMatch, int rateLog, int half) {
    final width = minMatch < 64 ? minMatch : 64;
    final start = rateLog > 0 && rateLog <= width ? width - rateLog : 0;
    var mask = 0;
    for (var bit = start; bit < start + rateLog; bit++) {
      if (bit >= half && bit < half + 32) mask |= 1 << (bit - half);
    }
    return mask;
  }

  int _feedWeb(Uint8List src, int at, int size) {
    var hi = _rollingHigh;
    var lo = _rolling;
    var count = 0;
    var n = 0;
    while (n < size) {
      final byte = src[at + n];
      final upper = zstdWebShift(hi, 1) | (lo >>> 31);
      final sum = zstdWebShift(lo, 1) + zstdLdmGearWords[byte * 2 + 1];
      lo = sum & 0xffffffff;
      hi = (upper + zstdLdmGearWords[byte * 2] + (sum >= 4294967296 ? 1 : 0)) &
          0xffffffff;
      n++;
      if ((hi & _stopMaskHigh) == 0 && (lo & _stopMask) == 0) {
        _splits[count++] = n;
        if (count == _batch) break;
      }
    }
    _rollingHigh = hi;
    _rolling = lo;
    _found = count;
    return n;
  }

  int _feed(Uint8List src, int at, int size) {
    if (!zstdUse64Bit) return _feedWeb(src, at, size);
    var hash = _rolling;
    final mask = _stopMask;
    var count = 0;
    var n = 0;
    while (n < size) {
      hash = (hash << 1) + _gear![src[at + n]];
      n++;
      if (hash & mask == 0) {
        _splits[count++] = n;
        if (count == _batch) {
          break;
        }
      }
    }
    _rolling = hash;
    _found = count;
    return n;
  }

  void _insert(int hash, int sum, int at) {
    final slot = (hash << bucketLog) + _next[hash];
    _entryPos[slot] = at + 1;
    _entrySum[slot] = sum;
    _next[hash] = (_next[hash] + 1) & ((1 << bucketLog) - 1);
  }

  static int _count(Uint8List src, ByteData view, int a, int b, int end) {
    if (!zstdUse64Bit) return zstdWebCount(src, view, a, b, end);
    var length = 0;
    while (a + length + 8 <= end) {
      if (view.getUint64(a + length, Endian.little) !=
          view.getUint64(b + length, Endian.little)) {
        break;
      }
      length += 8;
    }
    while (a + length < end && src[a + length] == src[b + length]) {
      length++;
    }
    return length;
  }

  /// `ZSTD_ldm_countBackwardsMatch`, which may not count back past the block's
  /// anchor or before the lowest position the window still holds
  static int _countBack(
      Uint8List src, int at, int anchor, int match, int floor) {
    var length = 0;
    while (at - length > anchor &&
        match - length > floor &&
        src[at - length - 1] == src[match - length - 1]) {
      length++;
    }
    return length;
  }
}

import 'dart:typed_data';

import 'zstd_bit_reader.dart';
import 'zstd_block_encoder.dart';

// The match finders that turn a block into sequences. Positions are indexes
// into the buffer the frame encoder keeps, which slides along a long input;
// the tables are moved along with it by [ZstdMatchFinder.slide].

/// x * p, modulo 2^32, for x and p below 2^32. Where ints are JavaScript
/// numbers the product would lose its low bits, so it is done in halves.
@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _mul32(int x, int p) => ZstdBitReader.has64BitInts
    ? (x * p) & 0xffffffff
    : ((((x >>> 16) * p) & 0xffff) * 0x10000 + (x & 0xffff) * p) & 0xffffffff;

// A hash of the [mls] bytes at [p], from 4 to 6, [log] bits wide. Eight bytes
// from [p] on must be readable.
@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _hashMls(ByteData d, int p, int mls, int log) {
  if (ZstdBitReader.has64BitInts) {
    return ((_read64(d, p) << (64 - 8 * mls)) * 0x165667B19E3779) >>>
        (64 - log);
  }
  final low = _read32(d, p);
  if (mls == 4) {
    return _mul32(low, 0x9E3779B1) >>> (32 - log);
  }
  final high = mls == 5 ? d.getUint8(p + 4) : d.getUint16(p + 4, Endian.little);
  return _mul32(low ^ _mul32(high + 1, 0x85EBCA77), 0x9E3779B1) >>> (32 - log);
}

// A hash of the eight bytes at [p], [log] bits wide.
@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _hash8(ByteData d, int p, int log) {
  if (ZstdBitReader.has64BitInts) {
    // The multiplier is below 2^53, so that this still compiles for
    // JavaScript, where this branch is never taken.
    return (_read64(d, p) * 0x165667B19E3779) >>> (64 - log);
  }
  final low = _read32(d, p);
  final high = _read32(d, p + 4);
  return _mul32(low ^ _mul32(high, 0x85EBCA77), 0x9E3779B1) >>> (32 - log);
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
@pragma('dart2js:prefer-inline')
int _read32(ByteData d, int p) => d.getUint32(p, Endian.little);

// Only where ints are 64 bits wide.
@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _read64(ByteData d, int p) => d.getUint64(p, Endian.little);

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
@pragma('dart2js:prefer-inline')
bool _equal8(ByteData d, int a, int b) => ZstdBitReader.has64BitInts
    ? _read64(d, a) == _read64(d, b)
    : _read32(d, a) == _read32(d, b) && _read32(d, a + 4) == _read32(d, b + 4);

/// How many bytes from [a] on match those from [b] on, stopping at [end].
@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _count(Uint8List src, ByteData d, int a, int b, int end) {
  final start = a;
  if (ZstdBitReader.has64BitInts) {
    while (a + 8 <= end) {
      final x = _read64(d, a) ^ _read64(d, b);
      if (x != 0) {
        return a - start + (((x & -x).bitLength - 1) >> 3);
      }
      a += 8;
      b += 8;
    }
  } else {
    while (a + 4 <= end) {
      final x = _read32(d, a) ^ _read32(d, b);
      if (x != 0) {
        return a - start + (((x & -x).bitLength - 1) >> 3);
      }
      a += 4;
      b += 4;
    }
  }
  while (a < end && src[a] == src[b]) {
    a++;
    b++;
  }
  return a - start;
}

// Positions a table no longer holds.
const int _empty = -1;

Int32List _table(int log) =>
    Int32List(1 << log)..fillRange(0, 1 << log, _empty);

void _slideTable(Int32List table, int shift) {
  for (var i = 0; i < table.length; i++) {
    final v = table[i] - shift;
    table[i] = v < 0 ? _empty : v;
  }
}

/// Finds the matches in a block.
abstract class ZstdMatchFinder {
  // The last two match offsets, which are the first places to look.
  int _rep1 = 1;
  int _rep2 = 4;

  /// Slides must be multiples of this, for tables indexed by position.
  int get slideAlignment => 1;

  /// Finds the sequences in [src] from [start] to [end], with up to
  /// [windowSize] bytes before [start] to refer back into, and adds them to
  /// [seqs].
  void findMatches(Uint8List src, ByteData d, int start, int end,
      int windowSize, ZstdSequenceStore seqs);

  /// Moves every position back by [shift], forgetting any that go below
  /// zero, after the buffer has moved that far.
  void slide(int shift);

  // Adds the position [p] to the tables, for a match found without them.
  void _index(ByteData d, int p) {}

  // After a match ending at [ip], matches at the second offset with no
  // literals between them, which cost next to nothing. Returns where they
  // end.
  int _repeatMatches(Uint8List src, ByteData d, int ip, int limit, int end,
      int windowSize, ZstdSequenceStore seqs) {
    while (ip < limit) {
      final rep = _rep2;
      if (rep > windowSize ||
          ip - rep < 0 ||
          _read32(d, ip) != _read32(d, ip - rep)) {
        break;
      }
      final length = 4 + _count(src, d, ip + 4, ip + 4 - rep, end);
      _rep2 = _rep1;
      _rep1 = rep;
      _index(d, ip);
      seqs.add(src, ip, 0, rep, length);
      ip += length;
    }
    return ip;
  }
}

/// One hash table, taking the first match it finds and skipping ahead faster
/// the longer it goes without one.
class ZstdFastMatchFinder extends ZstdMatchFinder {
  final int hashLog;
  final int mls;
  final int step;
  final Int32List _hashTable;

  ZstdFastMatchFinder(this.hashLog, this.mls, this.step)
      : _hashTable = _table(hashLog);

  @override
  void slide(int shift) => _slideTable(_hashTable, shift);

  @override
  void _index(ByteData d, int p) {
    _hashTable[_hashMls(d, p, mls, hashLog)] = p;
  }

  @override
  void findMatches(Uint8List src, ByteData d, int start, int end,
      int windowSize, ZstdSequenceStore seqs) {
    final table = _hashTable;
    final log = hashLog;
    final mls = this.mls;
    final limit = end - 8;
    var ip = start == 0 ? 1 : start;
    var anchor = start;

    while (ip < limit) {
      final current = _read32(d, ip);
      final h = _hashMls(d, ip, mls, log);
      final candidate = table[h];
      table[h] = ip;

      int length;
      int offset;
      final rep = _rep1;
      if (rep <= windowSize &&
          ip + 1 - rep >= 0 &&
          _read32(d, ip + 1 - rep) == _read32(d, ip + 1)) {
        ip++;
        offset = rep;
        length = 4 + _count(src, d, ip + 4, ip + 4 - rep, end);
      } else if (candidate != _empty &&
          ip - candidate <= windowSize &&
          _read32(d, candidate) == current &&
          (length = 4 + _count(src, d, ip + 4, candidate + 4, end)) >= mls) {
        var m = candidate;
        while (ip > anchor && m > 0 && src[ip - 1] == src[m - 1]) {
          ip--;
          m--;
          length++;
        }
        offset = ip - m;
        _rep2 = _rep1;
        _rep1 = offset;
      } else {
        ip += ((ip - anchor) >> 8) + step;
        continue;
      }

      seqs.add(src, anchor, ip - anchor, offset, length);
      final matchStart = ip;
      ip += length;
      anchor = ip;
      if (ip < limit) {
        table[_hashMls(d, matchStart + 2, mls, log)] = matchStart + 2;
        table[_hashMls(d, ip - 2, mls, log)] = ip - 2;
        ip = anchor = _repeatMatches(src, d, ip, limit, end, windowSize, seqs);
      }
    }
    seqs.addLastLiterals(src, anchor, end - anchor);
  }
}

/// Two hash tables, one of eight bytes for long matches and one of four for
/// the rest, preferring the long ones.
class ZstdDoubleFastMatchFinder extends ZstdMatchFinder {
  final int hashLog;
  final int longHashLog;
  final int mls;
  final Int32List _short;
  final Int32List _long;

  ZstdDoubleFastMatchFinder(this.hashLog, this.longHashLog, this.mls)
      : _short = _table(hashLog),
        _long = _table(longHashLog);

  @override
  void slide(int shift) {
    _slideTable(_short, shift);
    _slideTable(_long, shift);
  }

  @override
  void _index(ByteData d, int p) {
    _short[_hashMls(d, p, mls, hashLog)] = p;
    _long[_hash8(d, p, longHashLog)] = p;
  }

  @override
  void findMatches(Uint8List src, ByteData d, int start, int end,
      int windowSize, ZstdSequenceStore seqs) {
    final shortTable = _short;
    final longTable = _long;
    final log = hashLog;
    final mls = this.mls;
    final longLog = longHashLog;
    final limit = end - 8;
    var ip = start == 0 ? 1 : start;
    var anchor = start;

    while (ip < limit) {
      final current = _read32(d, ip);
      final hs = _hashMls(d, ip, mls, log);
      final hl = _hash8(d, ip, longLog);
      final shortCandidate = shortTable[hs];
      final longCandidate = longTable[hl];
      shortTable[hs] = ip;
      longTable[hl] = ip;

      int length;
      int offset;
      var isRepeat = false;
      final rep = _rep1;
      if (rep <= windowSize &&
          ip + 1 - rep >= 0 &&
          _read32(d, ip + 1 - rep) == _read32(d, ip + 1)) {
        ip++;
        offset = rep;
        length = 4 + _count(src, d, ip + 4, ip + 4 - rep, end);
        isRepeat = true;
      } else {
        int m;
        if (longCandidate != _empty &&
            ip - longCandidate <= windowSize &&
            _equal8(d, longCandidate, ip)) {
          m = longCandidate;
          length = 8 + _count(src, d, ip + 8, m + 8, end);
        } else if (shortCandidate != _empty &&
            ip - shortCandidate <= windowSize &&
            _read32(d, shortCandidate) == current &&
            (length = 4 + _count(src, d, ip + 4, shortCandidate + 4, end)) >=
                mls) {
          // A long match one byte on beats a short one here
          final hl1 = _hash8(d, ip + 1, longLog);
          final next = longTable[hl1];
          longTable[hl1] = ip + 1;
          if (next != _empty &&
              ip + 1 - next <= windowSize &&
              _equal8(d, next, ip + 1)) {
            ip++;
            m = next;
            length = 8 + _count(src, d, ip + 8, m + 8, end);
          } else {
            m = shortCandidate;
          }
        } else {
          ip += ((ip - anchor) >> 8) + 1;
          continue;
        }
        while (ip > anchor && m > 0 && src[ip - 1] == src[m - 1]) {
          ip--;
          m--;
          length++;
        }
        offset = ip - m;
      }
      if (!isRepeat) {
        _rep2 = _rep1;
        _rep1 = offset;
      }

      seqs.add(src, anchor, ip - anchor, offset, length);
      final matchStart = ip;
      ip += length;
      anchor = ip;
      if (ip < limit) {
        longTable[_hash8(d, matchStart + 2, longLog)] = matchStart + 2;
        shortTable[_hashMls(d, matchStart + 2, mls, log)] = matchStart + 2;
        longTable[_hash8(d, ip - 2, longLog)] = ip - 2;
        shortTable[_hashMls(d, ip - 1, mls, log)] = ip - 1;
        ip = anchor = _repeatMatches(src, d, ip, limit, end, windowSize, seqs);
      }
    }
    seqs.addLastLiterals(src, anchor, end - anchor);
  }
}

/// The lazy matching the hash chain and row match finders share: finding a
/// match, then checking up to [depth] positions further on for a better one
/// before taking it.
abstract class _LazyMatchFinder extends ZstdMatchFinder {
  final int searchLog;
  final int mls;
  final int depth;
  // A match this long is taken without searching or looking ahead further.
  final int targetLength;
  // Everything before this is in the tables.
  int _nextToUpdate = 0;

  // The result of the last search.
  int _bestLength = 0;
  int _bestOffset = 0;

  _LazyMatchFinder(this.searchLog, this.mls, this.depth, this.targetLength);

  // Finds the longest match at [ip], into _bestLength and _bestOffset; a
  // length of zero means none.
  void _search(Uint8List src, ByteData d, int ip, int end, int windowSize);

  // The length of a match at the first offset at [ip], or 0.
  int _repeatLength(
      Uint8List src, ByteData d, int ip, int end, int windowSize) {
    final rep = _rep1;
    if (rep > windowSize ||
        ip - rep < 0 ||
        _read32(d, ip) != _read32(d, ip - rep)) {
      return 0;
    }
    return 4 + _count(src, d, ip + 4, ip + 4 - rep, end);
  }

  @override
  void findMatches(Uint8List src, ByteData d, int start, int end,
      int windowSize, ZstdSequenceStore seqs) {
    final limit = end - 8;
    var ip = start == 0 ? 1 : start;
    var anchor = start;

    while (ip < limit) {
      // The best match here, a repeat being cheaper than a new offset
      var length = _repeatLength(src, d, ip, end, windowSize);
      var offset = _rep1;
      _search(src, d, ip, end, windowSize);
      if (_bestLength > length + 1) {
        length = _bestLength;
        offset = _bestOffset;
      }
      if (length < 4) {
        ip += 1 + ((ip - anchor) >> 8);
        continue;
      }

      // Then whether waiting a byte or two finds better
      for (var step = 0;
          step < depth && ip + 1 < limit && length < targetLength;
          step++) {
        final gain = length * 4 - (offset + 1).bitLength + 4;
        final repeatLength = _repeatLength(src, d, ip + 1, end, windowSize);
        if (repeatLength >= 4 && repeatLength * 4 > gain) {
          ip++;
          length = repeatLength;
          offset = _rep1;
          continue;
        }
        _search(src, d, ip + 1, end, windowSize);
        if (_bestLength >= 4 &&
            _bestLength * 4 - (_bestOffset + 1).bitLength > gain) {
          ip++;
          length = _bestLength;
          offset = _bestOffset;
          continue;
        }
        break;
      }

      while (ip > anchor &&
          ip - offset > 0 &&
          src[ip - 1] == src[ip - 1 - offset]) {
        ip--;
        length++;
      }
      if (offset != _rep1) {
        _rep2 = _rep1;
        _rep1 = offset;
      }
      seqs.add(src, anchor, ip - anchor, offset, length);
      ip += length;
      anchor = ip;
      if (ip < limit) {
        ip = anchor = _repeatMatches(src, d, ip, limit, end, windowSize, seqs);
      }
    }
    seqs.addLastLiterals(src, anchor, end - anchor);
  }
}

/// A hash chain searched up to 2^searchLog deep.
class ZstdLazyMatchFinder extends _LazyMatchFinder {
  final int hashLog;
  final int chainLog;
  final Int32List _head;
  final Int32List _chain;

  ZstdLazyMatchFinder(this.hashLog, this.chainLog, int searchLog, int mls,
      int depth, int targetLength)
      : _head = _table(hashLog),
        _chain = _table(chainLog),
        super(searchLog, mls, depth, targetLength);

  @override
  int get slideAlignment => 1 << chainLog;

  @override
  void slide(int shift) {
    _slideTable(_head, shift);
    _slideTable(_chain, shift);
    _nextToUpdate = _nextToUpdate > shift ? _nextToUpdate - shift : 0;
  }

  void _insertUpTo(ByteData d, int target) {
    final head = _head;
    final chain = _chain;
    final log = hashLog;
    final mls = this.mls;
    final mask = (1 << chainLog) - 1;
    for (var p = _nextToUpdate; p < target; p++) {
      final h = _hashMls(d, p, mls, log);
      chain[p & mask] = head[h];
      head[h] = p;
    }
    if (target > _nextToUpdate) {
      _nextToUpdate = target;
    }
  }

  @override
  void _search(Uint8List src, ByteData d, int ip, int end, int windowSize) {
    _insertUpTo(d, ip);
    final chain = _chain;
    final chainSize = 1 << chainLog;
    final mask = chainSize - 1;
    final low = ip - windowSize;
    final chainLow = ip - chainSize;
    final current = _read32(d, ip);
    var candidate = _head[_hashMls(d, ip, mls, hashLog)];
    var attempts = 1 << searchLog;
    var best = mls - 1;
    var bestOffset = 0;
    while (candidate >= 0 &&
        candidate >= low &&
        candidate > chainLow &&
        attempts-- > 0) {
      if (ip + best < end &&
          src[candidate + best] == src[ip + best] &&
          _read32(d, candidate) == current) {
        final length = 4 + _count(src, d, ip + 4, candidate + 4, end);
        final offset = ip - candidate;
        // Longer, by enough to pay for a larger offset, which costs bits
        if (length > best &&
            (bestOffset == 0 ||
                (length - best) * 4 >
                    offset.bitLength - bestOffset.bitLength)) {
          best = length;
          bestOffset = offset;
          if (length >= targetLength || ip + length >= end) {
            break;
          }
        }
      }
      candidate = chain[candidate & mask];
    }
    _bestLength = bestOffset == 0 ? 0 : best;
    _bestOffset = bestOffset;
  }
}

/// Rows of the most recent positions with each hash, as the reference library
/// does for its middle levels. Each position in a row carries eight more bits
/// of its hash, so most candidates are turned down without reading the data
/// they point to, which is what makes this faster than a chain.
class ZstdRowMatchFinder extends _LazyMatchFinder {
  final int rowLog;
  // The bits of hash that pick a row
  final int rowHashLog;
  final Int32List _positions;
  final Uint8List _tags;
  // Where the newest position in each row is
  final Uint8List _heads;
  // The hash the last search worked out, which inserting that position
  // needs again.
  int _hashedPosition = -1;
  int _hash = 0;

  ZstdRowMatchFinder(int hashLog, this.rowLog, int searchLog, int mls,
      int depth, int targetLength)
      : rowHashLog = hashLog - rowLog,
        _positions = _table(hashLog),
        _tags = Uint8List(1 << hashLog),
        _heads = Uint8List(1 << (hashLog - rowLog)),
        super(searchLog, mls, depth, targetLength);

  @override
  void slide(int shift) {
    _slideTable(_positions, shift);
    _nextToUpdate = _nextToUpdate > shift ? _nextToUpdate - shift : 0;
  }

  void _insertUpTo(ByteData d, int target) {
    _insertRange(d, _nextToUpdate, target);
    if (target > _nextToUpdate) {
      _nextToUpdate = target;
    }
  }

  void _insertRange(ByteData d, int from, int to) {
    final positions = _positions;
    final tags = _tags;
    final heads = _heads;
    final log = rowHashLog + 8;
    final mls = this.mls;
    final rowLog = this.rowLog;
    final rowMask = (1 << rowLog) - 1;
    for (var p = from; p < to; p++) {
      final h = p == _hashedPosition ? _hash : _hashMls(d, p, mls, log);
      final row = h >> 8;
      final head = (heads[row] - 1) & rowMask;
      heads[row] = head;
      final i = (row << rowLog) + head;
      positions[i] = p;
      tags[i] = h & 0xff;
    }
  }

  @override
  void _search(Uint8List src, ByteData d, int ip, int end, int windowSize) {
    _insertUpTo(d, ip);
    final positions = _positions;
    final tags = _tags;
    final rowLog = this.rowLog;
    final rowSize = 1 << rowLog;
    final rowMask = rowSize - 1;
    final h = _hashMls(d, ip, mls, rowHashLog + 8);
    _hashedPosition = ip;
    _hash = h;
    final row = h >> 8;
    final tag = h & 0xff;
    final base = row << rowLog;
    final head = _heads[row];
    final low = ip - windowSize;
    final current = _read32(d, ip);
    final attempts = searchLog < rowLog ? 1 << searchLog : rowSize;
    var best = mls - 1;
    var bestOffset = 0;
    // Newest first, so the rest are out of the window once one is
    for (var k = 0; k < attempts; k++) {
      final i = base + ((head + k) & rowMask);
      if (tags[i] != tag) {
        continue;
      }
      final candidate = positions[i];
      if (candidate < low || candidate < 0) {
        break;
      }
      if (ip + best < end &&
          src[candidate + best] == src[ip + best] &&
          _read32(d, candidate) == current) {
        final length = 4 + _count(src, d, ip + 4, candidate + 4, end);
        final offset = ip - candidate;
        // Longer, by enough to pay for a larger offset, which costs bits
        if (length > best &&
            (bestOffset == 0 ||
                (length - best) * 4 >
                    offset.bitLength - bestOffset.bitLength)) {
          best = length;
          bestOffset = offset;
          if (length >= targetLength || ip + length >= end) {
            break;
          }
        }
      }
    }
    _bestLength = bestOffset == 0 ? 0 : best;
    _bestOffset = bestOffset;
  }
}

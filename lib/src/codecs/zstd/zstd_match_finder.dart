import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_ldm.dart';
import 'zstd_level_params.dart';
import 'zstd_opt_prices.dart';
import 'zstd_sequences_encoder.dart';
import 'zstd_web.dart';

/// The shortest match this parse will take
const zstdMinMatch = 4;

/// What a sequence subtracts from a match length, three even where the parse
/// never looks for one that short
const zstdMatchLengthFloor = 3;

/// Constants of the byte at a time compare that tests a whole row of tags
const _x01 = (0x01010101 << 32) | 0x01010101;
const _x80 = (0x80808080 << 32) | 0x80808080;
const _gather = (0x00020408 << 32) | 0x10204081;

/// One multiply per key, the reference's own primes. The key is the top
/// `hashBytes` of a little endian eight byte read, shifted up so the bytes it
/// does not use fall off the bottom
const _primes = [
  0, 0, 0, 0, 2654435761, 889523592379, //
  227718039650203, (0x00cf1bbc << 32) | 0xdcbfa563,
  (0xcf1bbcdc << 32) | 0xb7a56463
];

/// The key of the double parse's long table, always over eight bytes
const _longPrime = (0xcf1bbcdc << 32) | 0xb7a56463;

/// The optimal parse's own three byte table. A level with a minimum match of
/// three finds one through it
const _shortPrime = 506832829;

/// `ZSTD_HASHLOG3_MAX`, which a narrow window cuts down
const _shortLogMax = 17;

/// Which search a level runs
/// The deferred tree holds a position raised by two, since zero marks a slot
/// never filled and one, `ZSTD_DUBT_UNSORTED_MARK`, a position that has joined
/// its hash's list but not yet been placed
const _lift = 2;
const _unsorted = 1;

const _searchRow = 0;
const _searchChain = 1;
const _searchTree = 2;

/// A de Bruijn sequence and its table, since `int.bitLength` on a value the
/// compiler cannot prove is a Smi becomes a call through the dispatch table
const _deBruijn = (0x022fdd63 << 32) | 0xcc95386d;

/// Where the one set bit of a value sits, indexed by `(v * _deBruijn) >>> 58`.
/// Stays const: the same table as a lazy `Uint8List` static cost 12.3% at level
/// 6
const _slots = <int>[
  0,
  1,
  2,
  53,
  3,
  7,
  54,
  27,
  4,
  38,
  41,
  8,
  34,
  55,
  48,
  28,
  62,
  5,
  39,
  46,
  44,
  42,
  22,
  9,
  24,
  35,
  59,
  56,
  49,
  18,
  29,
  11,
  63,
  52,
  6,
  26,
  37,
  40,
  33,
  47,
  61,
  45,
  43,
  21,
  23,
  58,
  17,
  10,
  51,
  25,
  36,
  32,
  60,
  20,
  57,
  16,
  50,
  31,
  19,
  15,
  30,
  14,
  13,
  12,
];

/// Older SDKs use this fallback; an int instance getter takes precedence, so
/// the comparison below folds and neither arm costs a branch. The intrinsic is
/// 4.18%
extension _ZstdTrailingZeroBitCount on int {
  @pragma('vm:prefer-inline')
  // ignore: unused_element
  int get trailingZeroBitCount => -1;
}

/// Callers pass a nonzero mismatch; the sentinel selects the SDK implementation
@pragma('vm:prefer-inline')
int _trailingZeroBitCount(int value) {
  // ignore: sdk_version_since
  if (0.trailingZeroBitCount < 0) {
    final low = value & -value;
    return _slots[(low * _deBruijn) >>> 58];
  }
  // ignore: sdk_version_since
  return value.trailingZeroBitCount;
}

/// The row loop has already isolated its lowest set bit
@pragma('vm:prefer-inline')
int _isolatedTrailingZeroBitCount(int low) {
  // ignore: sdk_version_since
  if (0.trailingZeroBitCount < 0) {
    return _slots[(low * _deBruijn) >>> 58];
  }
  // ignore: sdk_version_since
  return low.trailingZeroBitCount;
}

/// Finds the sequences of a block. A slot holds a position plus one, so zero
/// means it was never filled, and the tables hold absolute positions so they
/// stay valid across the blocks of a frame
class ZstdMatchFinder {
  final ZstdLevelParams params;
  final Uint32List _hashTable;
  final Uint32List _chain;
  final int _tries;
  final int _shift;

  /// The table's prime with the discard shift folded in, so hashing is one
  /// multiply: `(w << s) * p` and `w * (p << s)` agree modulo 2^64
  final int _keyMul;

  /// Candidates per row, sixteen or thirty two, and what addresses one
  final int _rowLog;
  final int _rowEntries;
  final int _rowMask;
  final int _entryMask;
  final int _words;

  /// What a row and tag key is shifted down by: enough bits for the row index
  /// and eight more for the tag
  final int _rowShift;

  /// Half the tree's node count less one, which addresses a node
  final int _btMask;

  /// Which search this level runs: a row of tags, a hash chain, or the tree
  final int _search;

  /// The shortest match this level takes, three only where it keeps a three
  /// byte table to find one
  final int _minMatch;

  /// Positions keyed on three bytes, for the levels whose minimum match is
  /// three. A slot holds a position plus one
  final int _shortLog;
  final Uint32List _short;
  int _nextShort = 0;

  /// A row of positions, its tags packed eight to a word, and the slot the
  /// last insertion took
  final Uint32List _rows;
  final TypedData _tags;
  final Uint8List _tagBytes;
  final int _tagByteXor = Endian.host == Endian.little ? 0 : 7;

  /// How far ahead the optimal parse plans, `ZSTD_OPT_NUM`
  static const _optMax = 1 << 12;

  /// Every match of one position, filled by [_allMatches]
  final Uint32List _matchLengths = Uint32List(_optMax);
  final Uint32List _matchOffBases = Uint32List(_optMax);
  final Uint32List _repScratch = Uint32List(3);
  final Uint32List _repHere = Uint32List(3);

  /// The parse's table, one entry a byte of lookahead. An entry is a stretch,
  /// a match followed by literals, the reverse of a sequence
  static const _optSize = _optMax + 3;
  final Int32List _optPrice = Int32List(_optSize);
  final Uint32List _optMlen = Uint32List(_optSize);
  final Uint32List _optLitlen = Uint32List(_optSize);
  final Uint32List _optOff = Uint32List(_optSize);
  final Uint32List _optRep = Uint32List(_optSize * 3);
  final ZstdOptPrices _prices = ZstdOptPrices();

  /// What the optimal parse prices its first block from when a dictionary put
  /// tables in front of it
  ZstdOptPrices get prices => _prices;
  final ZstdOptLdm _optLdm = ZstdOptLdm();

  /// The long distance matches of the block being parsed, which only the
  /// widest window of the optimal parse ever has
  ZstdLdmSequences? ldm;

  int _nextToUpdate = 0;
  int _foundOffset = 0;

  /// Where the data this frame codes begins. A dictionary sits before it as a
  /// segment of its own, so `window.dictLimit` is here rather than at the start
  /// of everything the parse can reach
  int prefixStart = 0;

  /// `prefixStart` as the window leaves it: once the window has slid past a
  /// dictionary the data is the whole prefix again
  @pragma('vm:prefer-inline')
  int _prefixFrom(int floor) => floor > prefixStart ? floor : prefixStart;

  /// `loadedDictEnd`: where a dictionary the frame still holds ends, zero once
  /// a block has left it further behind than the window is wide
  int dictionaryEnd = 0;

  /// `ZSTD_getLowestMatchIndex`: a whole dictionary stays reachable while any
  /// byte of it is in the window, so the bound is not applied until the frame
  /// drops it
  @pragma('vm:prefer-inline')
  int _lowestFrom(int at, int lowLimit, int maxDistance) {
    if (dictionaryEnd != 0) {
      return lowLimit;
    }
    return at - lowLimit > maxDistance ? at - maxDistance : lowLimit;
  }

  /// `ZSTD_getLowestMatchIndex` at the position a repeat is tried from. The
  /// extDict loops weigh every repeat against the window as it stands there,
  /// where the plain ones hold the far offsets aside once at the block's start
  @pragma('vm:prefer-inline')
  int _repFloor(int at, int lowLimit) =>
      _ext ? _lowestFrom(at, lowLimit, 1 << params.windowLog) : lowLimit;

  /// `prefixStartIndex == dictStartIndex`: the two fastest loops drop back to
  /// their plain variant when the window, measured from the end of the block,
  /// has caught up with the segment boundary and left nothing outside it. The
  /// deeper strategies have no such line and run their ext loop either way
  @pragma('vm:prefer-inline')
  bool _reaches(int end, int lowLimit) =>
      prefixStart > _lowestFrom(end, lowLimit, 1 << params.windowLog);

  /// True while a dictionary the parse can still reach sits before the data.
  /// The reference then runs a loop of its own for every strategy, and the
  /// differences are all in how a candidate is admitted
  bool _ext = false;

  /// `ZSTD_index_overlap_check`: a repeat that would read across the end of a
  /// dictionary is not usable, since the reference holds the two as separate
  /// buffers and cannot read one into the other
  @pragma('vm:prefer-inline')
  bool _spansDictionary(int at) => at < prefixStart && at > prefixStart - 4;

  /// `lazySkipping`: once the parse steps more than eight bytes at a time it
  /// stops inserting every position, only the ones it searches
  bool _skipping = false;

  /// The cast keeps the SDK 3.0 floor, where this conditional infers
  /// `List<int>`
  ZstdMatchFinder(ZstdLevelParams params)
      : this._(
            params,
            (zstdUse64Bit
                ? Uint64List(_usesRows(params) ? 1 << (params.hashLog - 3) : 1)
                : Uint8List(
                    _usesRows(params) ? 1 << params.hashLog : 8)) as TypedData);

  ZstdMatchFinder._(this.params, TypedData tags)
      : _tags = tags,
        _tagBytes = tags.buffer.asUint8List(),
        _hashTable = Uint32List(_usesTable(params) ? 1 << params.hashLog : 1),
        _chain = Uint32List(_usesChain(params) ? 1 << params.chainLog : 1),
        _btMask = params.strategy >= zstdStrategyBinaryTree
            ? (1 << (params.chainLog - 1)) - 1
            : 0,
        _search = params.strategy >= zstdStrategyBinaryTree
            ? _searchTree
            : (_usesChainSearch(params) ? _searchChain : _searchRow),
        _shortLog = _shortLogFor(params),
        _short =
            Uint32List(params.hashBytes == 3 ? 1 << _shortLogFor(params) : 1),
        _minMatch = params.hashBytes == 3 ? 3 : zstdMinMatch,
        _tries = _triesFor(params),
        _shift = 64 - params.hashLog,
        _keyMul = zstdUse64Bit
            ? _primes[params.hashBytes < 4 ? 4 : params.hashBytes] <<
                (64 - ((params.hashBytes < 4 ? 4 : params.hashBytes) << 3))
            : (params.hashBytes < 4 ? 4 : params.hashBytes),
        _rowLog = _rowLogFor(params),
        _rowEntries = 1 << _rowLogFor(params),
        _rowMask = (1 << _rowLogFor(params)) - 1,
        _entryMask = (1 << (1 << _rowLogFor(params))) - 1,
        _words = 1 << (_rowLogFor(params) - 3),
        _rowShift = 56 - params.hashLog + _rowLogFor(params),
        _rows = Uint32List(_usesRows(params) ? 1 << params.hashLog : 1);

  static int _shortLogFor(ZstdLevelParams params) =>
      params.windowLog < _shortLogMax ? params.windowLog : _shortLogMax;

  static bool _usesTable(ZstdLevelParams params) =>
      params.strategy < zstdStrategyGreedy ||
      params.strategy >= zstdStrategyBinaryTree ||
      _usesChainSearch(params);

  static bool _usesChain(ZstdLevelParams params) =>
      params.strategy == zstdStrategyDouble ||
      params.strategy >= zstdStrategyBinaryTree ||
      _usesChainSearch(params);

  /// `ZSTD_resolveRowMatchFinderMode`: a window this narrow does not justify a
  /// row of tags, and the reference searches a hash chain instead
  static bool _usesChainSearch(ZstdLevelParams params) =>
      (params.strategy == zstdStrategyGreedy ||
          params.strategy == zstdStrategyLazy) &&
      params.windowLog <= 14;

  static bool _usesRows(ZstdLevelParams params) =>
      (params.strategy == zstdStrategyGreedy ||
          params.strategy == zstdStrategyLazy) &&
      params.windowLog > 14;

  /// Sixteen candidates a row, or more where the level asks for a deeper
  /// search, exactly as `BOUNDED(4, searchLog, 6)` does in the reference
  static int _rowLogFor(ZstdLevelParams params) {
    if (params.searchLog < 4) {
      return 4;
    }
    return params.searchLog > 6 ? 6 : params.searchLog;
  }

  /// A row holds a fixed number of candidates, so a deeper search cannot see
  /// past it. The tree has no such bound and takes the level's own count
  static int _triesFor(ZstdLevelParams params) {
    final asked = 1 << params.searchLog;
    if (params.strategy >= zstdStrategyBinaryTree) {
      return asked;
    }
    final entries = 1 << _rowLogFor(params);
    return asked < entries ? asked : entries;
  }

  void reset() {
    _hashTable.fillRange(0, _hashTable.length, 0);
    _chain.fillRange(0, _chain.length, 0);
    _rows.fillRange(0, _rows.length, 0);
    if (zstdUse64Bit) {
      final tags = _tags as Uint64List;
      tags.fillRange(0, tags.length, 0);
    } else {
      _tagBytes.fillRange(0, _tagBytes.length, 0);
    }
    _nextToUpdate = 0;
    _nextShort = 0;
    _short.fillRange(0, _short.length, 0);
    dictionaryEnd = 0;
  }

  /// `ZSTD_cycleLog`: the chain and the tree address a node by the low bits of
  /// a position, so only a slide that leaves those bits alone keeps them
  /// reachable. The other searches key on the bytes and take any slide
  int get slideStep {
    if (params.strategy >= zstdStrategyBinaryTree) {
      return _btMask + 1;
    }
    return _usesChainSearch(params) ? 1 << params.chainLog : 1;
  }

  /// How many entries a slide has to visit. The cost is amortized over the
  /// bytes it frees
  int get slideCost =>
      _hashTable.length + _chain.length + _rows.length + _short.length;

  /// `ZSTD_reduceIndex`: the buffer moved [delta] bytes down, so every stored
  /// position moves with it and whatever fell off the front is dropped
  void slide(int delta) {
    if (params.strategy >= zstdStrategyBinaryTree) {
      _reduceTree(_hashTable, delta);
      _reduceTree(_chain, delta);
    } else {
      _reduce(_hashTable, delta);
      _reduce(_chain, delta);
    }
    _reduce(_rows, delta);
    _reduce(_short, delta);
    _nextToUpdate = _nextToUpdate > delta ? _nextToUpdate - delta : 0;
    _nextShort = _nextShort > delta ? _nextShort - delta : 0;
    prefixStart = prefixStart > delta ? prefixStart - delta : 0;
    dictionaryEnd = dictionaryEnd > delta ? dictionaryEnd - delta : 0;
  }

  /// A slot holds a position raised by one, so anything at or below the slide
  /// was pushed out of the buffer and reads as never filled
  static void _reduce(Uint32List table, int delta) {
    for (var at = 0; at < table.length; at++) {
      final held = table[at];
      table[at] = held <= delta ? 0 : held - delta;
    }
  }

  /// `ZSTD_reduceTable_btlazy2`: the tree raises a position by [_lift] and
  /// keeps [_unsorted] as a mark of its own. That mark is not a position
  static void _reduceTree(Uint32List table, int delta) {
    for (var at = 0; at < table.length; at++) {
      final held = table[at];
      if (held == _unsorted) {
        continue;
      }
      table[at] = held < delta + _lift ? 0 : held - delta;
    }
  }

  /// `ZSTD_window_update` on input that does not follow what came before: what
  /// is already held becomes a segment of its own, reached from here on through
  /// the ext paths, and insertion resumes at the cut
  void cut(int at) {
    prefixStart = at;
    _nextToUpdate = at;
  }

  /// Puts a dictionary's positions in this level's tables, so the first block
  /// can match into it rather than only through the repeat offsets it starts
  /// with. `ZSTD_loadDictionaryContent`
  /// The raw prefix a threaded job starts from: the same load, but the bytes
  /// stay ordinary input rather than a dictionary to keep whole
  void primeRaw(Uint8List src, int start, int end) {
    prime(src, start, end);
    dictionaryEnd = 0;
    // `window.dictLimit` is where the job's own buffer starts, prefix and all
    prefixStart = start;
  }

  void prime(Uint8List src, int start, int end) {
    // A dictionary wider than the tables can index is loaded from its end only
    var wide = params.hashLog + 3;
    if (params.chainLog + 1 > wide) {
      wide = params.chainLog + 1;
    }
    var from = start;
    if (wide < 31 && end - start > 1 << wide) {
      from = end - (1 << wide);
    }
    // Held from the dictionary's own end, not from where a clamped load starts
    dictionaryEnd = end;
    final limit = end - 8;
    if (limit <= from) {
      _nextToUpdate = end;
      _nextShort = end;
      return;
    }
    final view = ByteData.sublistView(src);
    // `ZSTD_dtlm_fast`, which one shot compression always uses: a third of
    // the positions go into the table, the rest are left out
    const step = 3;
    if (params.strategy == zstdStrategyFast) {
      for (var at = from; at + step < limit + 2; at += step) {
        _hashTable[_key(view, at)] = at + 1;
      }
    } else if (params.strategy == zstdStrategyDouble) {
      final longShift = 64 - params.hashLog;
      final shortShift = 64 - params.chainLog;
      for (var at = from; at + step - 1 <= limit; at += step) {
        if (!zstdUse64Bit) {
          _hashTable[_longKey(view, at, longShift)] = at + 1;
          _chain[_keyTo(view, at, shortShift)] = at + 1;
          continue;
        }
        final word = view.getUint64(at, Endian.little);
        _hashTable[(word * _longPrime) >>> longShift] = at + 1;
        _chain[(word * _keyMul) >>> shortShift] = at + 1;
      }
    } else if (_search == _searchRow) {
      _fill(view, from, limit);
    } else if (_search == _searchChain) {
      final chainMask = (1 << params.chainLog) - 1;
      for (var at = from; at < limit; at++) {
        final slot = _key(view, at);
        _chain[at & chainMask] = _hashTable[slot];
        _hashTable[slot] = at + 1;
      }
    } else {
      var at = from;
      while (at < limit) {
        at += _insertTree(src, view, at, limit, from, end);
      }
    }
    _nextToUpdate = end;
    _nextShort = end;
  }

  /// Fills [store] with the sequences covering `src[start...end]`, where a
  /// match may reach back as far as [lowLimit]. [rep] holds the three repeat
  /// offsets on entry and the block's final ones on return
  void parse(Uint8List src, int start, int end, int lowLimit,
      ZstdSequenceStore store, Uint32List rep) {
    store.reset();
    _skipping = false;
    // `ZSTD_compress_frameChunk` raises the cursor to the window before the
    // catch-up below reads it, so a position the window has dropped never
    // decides how far back the catch-up reaches
    if (_nextToUpdate < lowLimit) {
      _nextToUpdate = lowLimit;
    }
    // `ZSTD_buildSeqStore`: a match running over the end of the last block
    // leaves the tables far behind, and only the last positions before this
    // one are worth catching up on
    if (start > _nextToUpdate + 384) {
      final gap = start - _nextToUpdate - 384;
      _nextToUpdate = start - (gap < 192 ? gap : 192);
    }
    final view = ByteData.sublistView(src);
    // `ZSTD_matchState_dictMode`, which checks the window at block start
    _ext = prefixStart > lowLimit;
    if (params.strategy == zstdStrategyOptimal) {
      _parseOptimal(src, view, start, end, lowLimit, store, rep);
    } else if (params.strategy == zstdStrategyFast) {
      if (_reaches(end, lowLimit)) {
        _parseFastExt(src, view, start, end, lowLimit, store, rep);
      } else {
        _parseFast(src, view, start, end, lowLimit, store, rep);
      }
    } else if (params.strategy == zstdStrategyDouble) {
      if (_reaches(end, lowLimit)) {
        _parseDoubleExt(src, view, start, end, lowLimit, store, rep);
      } else {
        _parseDouble(src, view, start, end, lowLimit, store, rep);
      }
    } else {
      _parseChained(src, view, start, end, lowLimit, store, rep,
          params.strategy == zstdStrategyBinaryTree);
    }
  }

  /// `ZSTD_compressBlock_fast_noDict_generic`. Two adjacent positions are
  /// probed and inserted per pass, the repeat is tried a step ahead of them
  /// before any hash lookup, and a hit is extended backwards a byte
  void _parseFast(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    final ilimit = end - 8;
    // `prefixStartIndex`: a match is bounded by the window as it stands at the
    // end of the block, not at its start, or a sequence near the end would
    // name an offset the decoder no longer holds
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(end, lowLimit, maxDistance);
    final stepSize =
        params.targetLength + (params.targetLength == 0 ? 1 : 0) + 1;
    // The step widens once every `kStepIncr` bytes without a match. It keeps
    // incompressible input from costing a lookup a byte
    const stepIncr = 1 << (8 - 1);
    var anchor = start;
    var ip0 =
        start == _prefixFrom(floor) && floor >= prefixStart ? start + 1 : start;
    var rep0 = rep[0];
    var rep1 = rep[1];
    // A repeat that reaches outside the window is not usable here, and zero
    // marks it without a bounds test in the loop. `ZSTD_getLowestPrefixIndex`
    // measures from where the block starts, not from where it ends, and stops
    // at the segment the data is in rather than at the whole window
    final maxRep = ip0 - _prefixFrom(_lowestFrom(ip0, lowLimit, maxDistance));
    var saved0 = 0;
    var saved1 = 0;
    final table = _hashTable;
    final keyMul = _keyMul;
    final shift = _shift;
    if (rep1 > maxRep) {
      saved1 = rep1;
      rep1 = 0;
    }
    if (rep0 > maxRep) {
      saved0 = rep0;
      rep0 = 0;
    }

    while (true) {
      var step = stepSize;
      var nextStep = ip0 + stepIncr;
      var ip1 = ip0 + 1;
      var ip2 = ip0 + step;
      var ip3 = ip2 + 1;
      if (ip3 >= ilimit) {
        break;
      }
      var hash0 = _keyWith(view, ip0, keyMul, shift);
      var hash1 = _keyWith(view, ip1, keyMul, shift);
      var held = table[hash0];

      var match = -1;
      var length = 0;
      var code = 0;
      // The position the table last took. The fill below starts from it, and a
      // repeat moves `ip0` on before that fill runs
      var current0 = ip0;

      do {
        current0 = ip0;
        table[hash0] = ip0 + 1;
        // The reference loads the repeat's bytes before it tests the offset,
        // and `ip2 - 0` is `ip2`, so a dead repeat fails on the second test
        // rather than costing a branch on the first
        if (view.getUint32(ip2, Endian.little) ==
                view.getUint32(ip2 - rep0, Endian.little) &&
            rep0 > 0) {
          ip0 = ip2;
          var at = ip0 - rep0;
          length = at > lowLimit && src[ip0 - 1] == src[at - 1] ? 1 : 0;
          ip0 -= length;
          at -= length;
          match = at;
          code = 1;
          length += zstdMinMatch;
          table[hash1] = ip1 + 1;
          break;
        }
        // A slot holds a position plus one, so an empty one reads as -1 here
        // and fails the window test without a compare of its own
        if (held - 1 >= floor &&
            view.getUint32(ip0, Endian.little) ==
                view.getUint32(held - 1, Endian.little)) {
          table[hash1] = ip1 + 1;
          match = held - 1;
          break;
        }

        held = table[hash1];
        hash0 = hash1;
        hash1 = _keyWith(view, ip2, keyMul, shift);
        ip0 = ip1;
        ip1 = ip2;
        ip2 = ip3;
        current0 = ip0;
        table[hash0] = ip0 + 1;
        if (held - 1 >= floor &&
            view.getUint32(ip0, Endian.little) ==
                view.getUint32(held - 1, Endian.little)) {
          // Past a step of four the next position is already behind where the
          // search resumes, so writing it would only stale the table
          if (step <= 4) {
            table[hash1] = ip1 + 1;
          }
          match = held - 1;
          break;
        }

        held = table[hash1];
        hash0 = hash1;
        hash1 = _keyWith(view, ip2, keyMul, shift);
        ip0 = ip1;
        ip1 = ip2;
        ip2 = ip0 + step;
        ip3 = ip1 + step;
        if (ip2 >= nextStep) {
          step++;
          nextStep += stepIncr;
        }
      } while (ip3 < ilimit);

      if (match < 0) {
        break;
      }

      final inside = current0 + 2;
      if (code == 0) {
        rep1 = rep0;
        rep0 = ip0 - match;
        code = rep0 + 3;
        length = zstdMinMatch;
        while (
            ip0 > anchor && match > floor && src[ip0 - 1] == src[match - 1]) {
          ip0--;
          match--;
          length++;
        }
      }

      length += _extend(src, view, ip0 + length, match + length, end);
      store.add(src, anchor, ip0 - anchor, code, length - zstdMatchLengthFloor);
      ip0 += length;
      anchor = ip0;

      if (ip0 <= ilimit) {
        _hashTable[_key(view, inside)] = inside + 1;
        _hashTable[_key(view, ip0 - 2)] = ip0 - 1;
        while (rep1 > 0 &&
            ip0 <= ilimit &&
            view.getUint32(ip0, Endian.little) ==
                view.getUint32(ip0 - rep1, Endian.little)) {
          final run = zstdMinMatch +
              _extend(src, view, ip0 + zstdMinMatch, ip0 - rep1 + zstdMinMatch,
                  end);
          final held2 = rep1;
          rep1 = rep0;
          rep0 = held2;
          _hashTable[_key(view, ip0)] = ip0 + 1;
          ip0 += run;
          store.add(src, anchor, 0, 1, run - zstdMatchLengthFloor);
          anchor = ip0;
        }
      }
    }

    store.finish(src, anchor, end);
    rep[0] = rep0 != 0 ? rep0 : saved0;
    rep[1] = rep1 != 0 ? rep1 : (saved0 != 0 && rep0 != 0 ? saved0 : saved1);
    rep[2] = rep[2];
  }

  /// `ZSTD_compressBlock_fast_extDict_generic`. The same two positions a pass
  /// as the plain loop, with every candidate placed in the dictionary or in the
  /// data before it is read, and a repeat that would span the two rejected
  void _parseFastExt(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    final ilimit = end - 8;
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(end, lowLimit, maxDistance);
    final prefix = _prefixFrom(floor);
    final stepSize =
        params.targetLength + (params.targetLength == 0 ? 1 : 0) + 1;
    const stepIncr = 1 << (8 - 1);
    final table = _hashTable;
    final keyMul = _keyMul;
    final shift = _shift;
    var anchor = start;
    var ip0 = start;
    var rep0 = rep[0];
    var rep1 = rep[1];
    var saved0 = 0;
    var saved1 = 0;
    // Held aside on `>=` rather than the `>` the plain loop uses
    final maxRep = ip0 - floor;
    if (rep1 >= maxRep) {
      saved1 = rep1;
      rep1 = 0;
    }
    if (rep0 >= maxRep) {
      saved0 = rep0;
      rep0 = 0;
    }

    while (true) {
      var step = stepSize;
      var nextStep = ip0 + stepIncr;
      var ip1 = ip0 + 1;
      var ip2 = ip0 + step;
      var ip3 = ip2 + 1;
      if (ip3 >= ilimit) {
        break;
      }
      var hash0 = _keyWith(view, ip0, keyMul, shift);
      var hash1 = _keyWith(view, ip1, keyMul, shift);
      var held = table[hash0] - 1;

      var match = -1;
      var length = 0;
      var code = 0;
      var current0 = ip0;

      do {
        final repeat = ip2 - rep0;
        current0 = ip0;
        table[hash0] = ip0 + 1;
        // `(U32)(prefixStartIndex - repIndex) >= 4`, which rejects a repeat
        // landing on the boundary as well as one straddling it. Every other
        // site in the reference takes the boundary itself
        if (rep0 > 0 &&
            (repeat <= prefix - 4 || repeat > prefix) &&
            view.getUint32(ip2, Endian.little) ==
                view.getUint32(repeat, Endian.little)) {
          ip0 = ip2;
          var at = repeat;
          length = src[ip0 - 1] == src[at - 1] ? 1 : 0;
          ip0 -= length;
          at -= length;
          match = at;
          code = 1;
          length += zstdMinMatch;
          break;
        }
        if (held >= floor &&
            view.getUint32(ip0, Endian.little) ==
                view.getUint32(held, Endian.little)) {
          match = held;
          break;
        }

        held = table[hash1] - 1;
        hash0 = hash1;
        hash1 = _keyWith(view, ip2, keyMul, shift);
        ip0 = ip1;
        ip1 = ip2;
        ip2 = ip3;
        current0 = ip0;
        table[hash0] = ip0 + 1;
        if (held >= floor &&
            view.getUint32(ip0, Endian.little) ==
                view.getUint32(held, Endian.little)) {
          match = held;
          break;
        }

        held = table[hash1] - 1;
        hash0 = hash1;
        hash1 = _keyWith(view, ip2, keyMul, shift);
        ip0 = ip1;
        ip1 = ip2;
        ip2 = ip0 + step;
        ip3 = ip1 + step;
        if (ip2 >= nextStep) {
          step++;
          nextStep += stepIncr;
        }
      } while (ip3 < ilimit);

      if (match < 0) {
        break;
      }

      final inside = current0 + 2;
      if (code == 0) {
        rep1 = rep0;
        rep0 = current0 - match;
        code = rep0 + 3;
        length = zstdMinMatch;
        // `dictStart`, the window as the end of the block leaves it
        final low = match < prefix ? floor : prefix;
        while (ip0 > anchor && match > low && src[ip0 - 1] == src[match - 1]) {
          ip0--;
          match--;
          length++;
        }
      }

      length += _extend(src, view, ip0 + length, match + length, end);
      store.add(src, anchor, ip0 - anchor, code, length - zstdMatchLengthFloor);
      ip0 += length;
      anchor = ip0;

      // The position the second probe took, which the match ran past
      if (ip1 < ip0) {
        table[hash1] = ip1 + 1;
      }

      if (ip0 <= ilimit) {
        table[_key(view, inside)] = inside + 1;
        table[_key(view, ip0 - 2)] = ip0 - 1;
        while (ip0 <= ilimit) {
          final held2 = ip0 - rep1;
          if (rep1 == 0 ||
              _spansDictionary(held2) ||
              view.getUint32(held2, Endian.little) !=
                  view.getUint32(ip0, Endian.little)) {
            break;
          }
          final run = zstdMinMatch +
              _extend(src, view, ip0 + zstdMinMatch, held2 + zstdMinMatch, end);
          final swap = rep1;
          rep1 = rep0;
          rep0 = swap;
          table[_key(view, ip0)] = ip0 + 1;
          ip0 += run;
          store.add(src, anchor, 0, 1, run - zstdMatchLengthFloor);
          anchor = ip0;
        }
      }
    }

    store.finish(src, anchor, end);
    if (saved0 != 0 && rep0 != 0) {
      saved1 = saved0;
    }
    rep[0] = rep0 != 0 ? rep0 : saved0;
    rep[1] = rep1 != 0 ? rep1 : saved1;
  }

  /// `ZSTD_compressBlock_doubleFast_extDict_generic`: one position a pass
  /// rather than two, since a dictionary lies in a buffer of its own and every
  /// candidate has to be placed in one or the other before it is read
  void _parseDoubleExt(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    final ilimit = end - 8;
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(end, lowLimit, maxDistance);
    final prefix = _prefixFrom(floor);
    final longShift = 64 - params.hashLog;
    final shortShift = 64 - params.chainLog;
    var anchor = start;
    var ip = start;
    var rep0 = rep[0];
    var rep1 = rep[1];

    while (ip < ilimit) {
      // The position the tables took this pass, which the insertion after a
      // match measures from rather than from where the match was finally placed
      final curr = ip;
      final shortSlot = _keyTo(view, ip, shortShift);
      final longSlot = _longKey(view, ip, longShift);
      final shortHit = _chain[shortSlot] - 1;
      final longHit = _hashTable[longSlot] - 1;
      _chain[shortSlot] = ip + 1;
      _hashTable[longSlot] = ip + 1;

      final repeat = ip + 1 - rep0;
      var length = 0;
      if (!_spansDictionary(repeat) &&
          rep0 <= ip + 1 - floor &&
          view.getUint32(repeat, Endian.little) ==
              view.getUint32(ip + 1, Endian.little)) {
        length = 4 + _extend(src, view, ip + 5, repeat + 4, end);
        ip++;
        store.add(src, anchor, ip - anchor, 1, length - zstdMatchLengthFloor);
      } else if (longHit > floor && _same8(view, longHit, ip)) {
        length = 8 + _extend(src, view, ip + 8, longHit + 8, end);
        var match = longHit;
        // `dictStart` is `ZSTD_getLowestMatchIndex` taken at the end of the
        // block, so it is `floor`. The lazy loops catch up to `window.lowLimit`
        // instead, and that one is not the same number once the window has
        // moved past a segment boundary
        final low = match < prefix ? floor : prefix;
        while (ip > anchor && match > low && src[ip - 1] == src[match - 1]) {
          ip--;
          match--;
          length++;
        }
        rep1 = rep0;
        rep0 = ip - match;
        store.add(
            src, anchor, ip - anchor, rep0 + 3, length - zstdMatchLengthFloor);
      } else if (shortHit > floor &&
          view.getUint32(shortHit, Endian.little) ==
              view.getUint32(ip, Endian.little)) {
        final aheadSlot = _longKey(view, ip + 1, longShift);
        final ahead = _hashTable[aheadSlot] - 1;
        _hashTable[aheadSlot] = ip + 2;
        var match = shortHit;
        if (ahead > floor && _same8(view, ahead, ip + 1)) {
          length = 8 + _extend(src, view, ip + 9, ahead + 8, end);
          ip++;
          match = ahead;
        } else {
          length = 4 + _extend(src, view, ip + 4, match + 4, end);
        }
        final low = match < prefix ? floor : prefix;
        while (ip > anchor && match > low && src[ip - 1] == src[match - 1]) {
          ip--;
          match--;
          length++;
        }
        rep1 = rep0;
        rep0 = ip - match;
        store.add(
            src, anchor, ip - anchor, rep0 + 3, length - zstdMatchLengthFloor);
      } else {
        ip += ((ip - anchor) >> 8) + 1;
        continue;
      }

      ip += length;
      anchor = ip;

      if (ip <= ilimit) {
        // The two positions the match ran over, and the two before its end
        final inside = curr + 2;
        _hashTable[_longKey(view, inside, longShift)] = inside + 1;
        _hashTable[_longKey(view, ip - 2, longShift)] = ip - 1;
        _chain[_keyTo(view, inside, shortShift)] = inside + 1;
        _chain[_keyTo(view, ip - 1, shortShift)] = ip;

        while (ip <= ilimit) {
          final held = ip - rep1;
          if (_spansDictionary(held) ||
              rep1 > ip - floor ||
              view.getUint32(held, Endian.little) !=
                  view.getUint32(ip, Endian.little)) {
            break;
          }
          final more = 4 + _extend(src, view, ip + 4, held + 4, end);
          final swap = rep1;
          rep1 = rep0;
          rep0 = swap;
          store.add(src, anchor, 0, 1, more - zstdMatchLengthFloor);
          _chain[_keyTo(view, ip, shortShift)] = ip + 1;
          _hashTable[_longKey(view, ip, longShift)] = ip + 1;
          ip += more;
          anchor = ip;
        }
      }
    }

    rep[0] = rep0;
    rep[1] = rep1;
    store.finish(src, anchor, end);
  }

  /// `ZSTD_compressBlock_doubleFast_noDict_generic`. Two tables, one keyed on
  /// eight bytes and one on the level's own width: a hit in the short table is
  /// kept only if the long table has nothing better one position on
  void _parseDouble(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    final ilimit = end - 8;
    // `prefixLowestIndex`, from the end of the block: a match may not name
    // an offset the decoder will no longer hold by the time it reads it
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(end, lowLimit, maxDistance);
    const stepIncr = 1 << 8;
    final longShift = 64 - params.hashLog;
    final shortShift = 64 - params.chainLog;
    var anchor = start;
    var ip =
        start == _prefixFrom(floor) && floor >= prefixStart ? start + 1 : start;
    var rep0 = rep[0];
    var rep1 = rep[1];
    // `ZSTD_getLowestPrefixIndex` again, measured from where the block starts
    final maxRep = ip - _prefixFrom(_lowestFrom(ip, lowLimit, maxDistance));
    var saved0 = 0;
    var saved1 = 0;
    if (rep1 > maxRep) {
      saved1 = rep1;
      rep1 = 0;
    }
    if (rep0 > maxRep) {
      saved0 = rep0;
      rep0 = 0;
    }

    while (true) {
      var step = 1;
      var nextStep = ip + stepIncr;
      var ip1 = ip + step;
      if (ip1 > ilimit) {
        break;
      }
      var longSlot = _longKey(view, ip, longShift);
      var heldLong = _hashTable[longSlot];

      var match = -1;
      var length = 0;
      var code = 0;
      var here = ip;
      var longSlot1 = 0;
      var stored = false;

      do {
        final shortSlot = _keyTo(view, ip, shortShift);
        final heldShort = _chain[shortSlot];
        here = ip;
        _hashTable[longSlot] = ip + 1;
        _chain[shortSlot] = ip + 1;

        if (rep0 > 0 &&
            view.getUint32(ip + 1 - rep0, Endian.little) ==
                view.getUint32(ip + 1, Endian.little)) {
          length = zstdMinMatch +
              _extendRow(src, view, ip + 1 + zstdMinMatch,
                  ip + 1 - rep0 + zstdMinMatch, end);
          ip++;
          store.add(src, anchor, ip - anchor, 1, length - zstdMatchLengthFloor);
          stored = true;
          break;
        }

        longSlot1 = _longKey(view, ip1, longShift);

        if (heldLong != 0 &&
            heldLong - 1 >= floor &&
            _same8(view, heldLong - 1, ip)) {
          match = heldLong - 1;
          length = 8 + _extendRow(src, view, ip + 8, match + 8, end);
          while (
              ip > anchor && match > floor && src[ip - 1] == src[match - 1]) {
            ip--;
            match--;
            length++;
          }
          break;
        }

        final heldLong1 = _hashTable[longSlot1];

        if (heldShort != 0 &&
            heldShort - 1 >= floor &&
            view.getUint32(heldShort - 1, Endian.little) ==
                view.getUint32(ip, Endian.little)) {
          match = heldShort - 1;
          length = zstdMinMatch +
              _extendRow(
                  src, view, ip + zstdMinMatch, match + zstdMinMatch, end);
          // A short hit is only worth taking if the long table has nothing
          // longer one position on
          // The reference tests this one strictly, unlike the two above it
          if (heldLong1 - 1 > floor && _same8(view, heldLong1 - 1, ip1)) {
            final other =
                8 + _extendRow(src, view, ip1 + 8, heldLong1 - 1 + 8, end);
            if (other > length) {
              ip = ip1;
              length = other;
              match = heldLong1 - 1;
            }
          }
          while (
              ip > anchor && match > floor && src[ip - 1] == src[match - 1]) {
            ip--;
            match--;
            length++;
          }
          break;
        }

        if (ip1 >= nextStep) {
          step++;
          nextStep += stepIncr;
        }
        ip = ip1;
        ip1 += step;
        longSlot = longSlot1;
        heldLong = heldLong1;
      } while (ip1 <= ilimit);

      if (!stored) {
        if (match < 0) {
          break;
        }
        rep1 = rep0;
        rep0 = ip - match;
        code = rep0 + 3;
        // Writing this back is only safe while the next position is behind
        // where the search resumes, which a step under four guarantees
        if (step < 4) {
          _hashTable[longSlot1] = ip1 + 1;
        }
        store.add(
            src, anchor, ip - anchor, code, length - zstdMatchLengthFloor);
      }

      ip += length;
      anchor = ip;

      if (ip <= ilimit) {
        final inside = here + 2;
        _hashTable[_longKey(view, inside, longShift)] = inside + 1;
        _hashTable[_longKey(view, ip - 2, longShift)] = ip - 1;
        _chain[_keyTo(view, inside, shortShift)] = inside + 1;
        _chain[_keyTo(view, ip - 1, shortShift)] = ip;

        while (ip <= ilimit &&
            rep1 > 0 &&
            view.getUint32(ip, Endian.little) ==
                view.getUint32(ip - rep1, Endian.little)) {
          final run = zstdMinMatch +
              _extendRow(
                  src, view, ip + zstdMinMatch, ip - rep1 + zstdMinMatch, end);
          final held = rep1;
          rep1 = rep0;
          rep0 = held;
          _chain[_keyTo(view, ip, shortShift)] = ip + 1;
          _hashTable[_longKey(view, ip, longShift)] = ip + 1;
          store.add(src, anchor, 0, 1, run - zstdMatchLengthFloor);
          ip += run;
          anchor = ip;
        }
      }
    }

    store.finish(src, anchor, end);
    rep[0] = rep0 != 0 ? rep0 : saved0;
    rep[1] = rep1 != 0 ? rep1 : (saved0 != 0 && rep0 != 0 ? saved0 : saved1);
  }

  void _parseChained(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep, bool tree) {
    // The row finder keeps a cache of the next eight hashes, so the reference
    // stops a cache short of where the other two searches stop
    final limit = end - zstdMinMatch - 4 - (_search == _searchRow ? 8 : 0);
    final depth = params.depth;
    var anchor = start;
    var ip = start == _prefixFrom(lowLimit) ? start + 1 : start;
    if (_nextToUpdate < lowLimit) {
      _nextToUpdate = lowLimit;
    }
    var rep0 = rep[0];
    var rep1 = rep[1];
    // An offset reaching further back than this block can see is held aside
    // rather than used, and passed on again if nothing displaces it
    final reach = 1 << params.windowLog;
    final maxRep = ip < reach ? ip : reach;
    var saved0 = 0;
    var saved1 = 0;
    // The extDict loop has no equivalent: it checks every repeat against the
    // window in the loop instead of computing one bound at the start
    if (!_ext) {
      if (rep1 > maxRep) {
        saved1 = rep1;
        rep1 = 0;
      }
      if (rep0 > maxRep) {
        saved0 = rep0;
        rep0 = 0;
      }
    }

    while (ip < limit) {
      var length = 0;
      var code = 1;
      var from = ip + 1;

      final repeat = ip + 1 - rep0;
      final haveRep = rep0 > 0 &&
          repeat >= _repFloor(ip + 1, lowLimit) &&
          !_spansDictionary(repeat) &&
          view.getUint32(repeat, Endian.little) ==
              view.getUint32(ip + 1, Endian.little);
      if (haveRep) {
        length = zstdMinMatch +
            _extend(
                src, view, ip + 1 + zstdMinMatch, repeat + zstdMinMatch, end);
      }

      if (!haveRep || depth > 0) {
        final found = _searchAt(src, view, ip, lowLimit, end);
        if (found > length) {
          length = found;
          from = ip;
          code = _foundOffset + 3;
        }
        if (length < zstdMinMatch) {
          final step = (ip - anchor) >> 8;
          // The plain loop folds the one into `step` before weighing it against
          // `kLazySkippingStep`, the extDict loop adds it after, so the two
          // enter the skipping mode a position apart
          _skipping = (_ext ? step : step + 1) > 8;
          ip += step + 1;
          continue;
        }

        // A match further on has to gain more than the literals it leaves
        // behind, priced the way the reference prices them
        while (depth > 0 && ip < limit) {
          ip++;
          final ahead = ip - rep0;
          if (rep0 > 0 &&
              ahead >= _repFloor(ip, lowLimit) &&
              !_spansDictionary(ahead) &&
              view.getUint32(ahead, Endian.little) ==
                  view.getUint32(ip, Endian.little)) {
            final repLength = zstdMinMatch +
                _extend(
                    src, view, ip + zstdMinMatch, ahead + zstdMinMatch, end);
            if (repLength * 3 > length * 3 - zstdHighestBit(code) + 1) {
              length = repLength;
              code = 1;
              from = ip;
            }
          }
          final later = _searchAt(src, view, ip, lowLimit, end);
          if (later >= zstdMinMatch &&
              later * 4 - zstdHighestBit(_foundOffset + 3) >
                  length * 4 - zstdHighestBit(code) + 4) {
            length = later;
            code = _foundOffset + 3;
            from = ip;
            continue;
          }
          if (depth == 2 && ip < limit) {
            ip++;
            final second = ip - rep0;
            if (rep0 > 0 &&
                second >= _repFloor(ip, lowLimit) &&
                !_spansDictionary(second) &&
                view.getUint32(second, Endian.little) ==
                    view.getUint32(ip, Endian.little)) {
              final repLength = zstdMinMatch +
                  _extend(
                      src, view, ip + zstdMinMatch, second + zstdMinMatch, end);
              if (repLength * 4 > length * 4 - zstdHighestBit(code) + 1) {
                length = repLength;
                code = 1;
                from = ip;
              }
            }
            final deeper = _searchAt(src, view, ip, lowLimit, end);
            if (deeper >= zstdMinMatch &&
                deeper * 4 - zstdHighestBit(_foundOffset + 3) >
                    length * 4 - zstdHighestBit(code) + 7) {
              length = deeper;
              code = _foundOffset + 3;
              from = ip;
              continue;
            }
          }
          break;
        }

        if (code > 3) {
          final offset = code - 3;
          final match = from - offset;
          final back = _extendBack(src, from, match, anchor,
              match < prefixStart ? lowLimit : _prefixFrom(lowLimit));
          from -= back;
          length += back;
          rep1 = rep0;
          rep0 = offset;
        }
      }
      _skipping = false;
      store.add(
          src, anchor, from - anchor, code, length - zstdMatchLengthFloor);
      ip = from + length;
      rep[0] = rep0;
      rep[1] = rep1;
      ip = _immediate(src, view, ip, limit, lowLimit, end, store, rep);
      rep0 = rep[0];
      rep1 = rep[1];
      anchor = ip;
    }

    store.finish(src, anchor, end);
    rep[0] = rep0 != 0 ? rep0 : saved0;
    rep[1] = rep1 != 0 ? rep1 : (saved0 != 0 && rep0 != 0 ? saved0 : saved1);
  }

  /// Takes every match at the second repeat offset that starts right where the
  /// last one ended, each costing one bit of offset and no literal
  int _immediate(Uint8List src, ByteData view, int ip, int limit, int lowLimit,
      int end, ZstdSequenceStore store, Uint32List rep) {
    while (ip <= limit) {
      final held = rep[1];
      final at = ip - held;
      if (held == 0 ||
          at < _repFloor(ip, lowLimit) ||
          _spansDictionary(at) ||
          view.getUint32(at, Endian.little) !=
              view.getUint32(ip, Endian.little)) {
        break;
      }
      final length = zstdMinMatch +
          _extend(src, view, ip + zstdMinMatch, at + zstdMinMatch, end);
      rep[1] = rep[0];
      rep[0] = held;
      store.add(src, ip, 0, 1, length - zstdMatchLengthFloor);
      ip += length;
    }
    return ip;
  }

  @pragma('vm:prefer-inline')
  int _searchAt(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    if (_search == _searchTree) {
      return _bestTree(src, view, ip, lowLimit, end);
    }
    return _search == _searchChain
        ? _bestChain(src, view, ip, lowLimit, end)
        : _best(src, view, ip, lowLimit, end);
  }

  /// `ZSTD_HcFindBestMatch`, the hash chain search. A slot holds a position
  /// plus one and the chain is indexed by the position it belongs to
  int _bestChain(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(ip, lowLimit, maxDistance);
    final chainSize = 1 << params.chainLog;
    final chainMask = chainSize - 1;
    final minChain = ip > chainSize ? ip - chainSize : 0;
    var tries = 1 << params.searchLog;
    var best = zstdMinMatch - 1;
    var found = 0;
    var match = _insertChain(view, ip) - 1;

    while (match >= floor && tries > 0) {
      tries--;
      // `ZSTD_HcFindBestMatch`: a candidate the dictionary holds is filtered on
      // its first four bytes, one inside the data on the byte at the length it
      // has to beat
      final int length;
      if (match < prefixStart) {
        length = view.getUint32(match, Endian.little) ==
                view.getUint32(ip, Endian.little)
            ? 4 + _extendRow(src, view, ip + 4, match + 4, end)
            : 0;
      } else {
        length = view.getUint32(match + best - 3, Endian.little) ==
                view.getUint32(ip + best - 3, Endian.little)
            ? _extendRow(src, view, ip, match, end)
            : 0;
      }
      if (length > best) {
        best = length;
        found = ip - match;
        if (ip + length >= end) {
          break;
        }
      }
      if (match <= minChain) {
        break;
      }
      match = _chain[match & chainMask] - 1;
    }

    _foundOffset = found;
    return best;
  }

  /// `ZSTD_insertAndFindFirstIndex_internal`: links every position up to [ip]
  /// into its chain and returns the head of [ip]'s own
  int _insertChain(ByteData view, int ip) {
    final chainMask = (1 << params.chainLog) - 1;
    var at = _nextToUpdate;
    while (at < ip) {
      final slot = _key(view, at);
      _chain[at & chainMask] = _hashTable[slot];
      _hashTable[slot] = at + 1;
      at++;
      if (_skipping) {
        break;
      }
    }
    _nextToUpdate = ip;
    return _hashTable[_key(view, ip)];
  }

  /// The longest match at [ip], with [_foundOffset] set to its distance.
  ///
  /// The candidates of one hash sit together in a row, their tags packed a byte
  /// each, so a whole row is tested for the tag in a couple of words and only a
  /// tag hit costs a look at the input
  int _bestWeb(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    final floor = _lowestFrom(ip, lowLimit, 1 << params.windowLog);
    var best = zstdMinMatch - 1;
    var found = 0;
    _insert(view, ip);
    final keyed = _keyTo(view, ip, _rowShift);
    final row = keyed >>> 8;
    final tag = keyed & 0xff;
    final head = _tagBytes[(row << _rowLog) ^ _tagByteXor];
    final base = row << _rowLog;
    var tries = _tries;
    var probe = view.getUint32(ip, Endian.little);
    for (var n = 0; n < _rowEntries && tries > 0; n++) {
      final entry = (head + n) & _rowMask;
      if (entry == 0 || _tagBytes[base + entry] != tag) continue;
      final candidate = _rows[base + entry] - 1;
      if (candidate < floor) break;
      tries--;
      if (view.getUint32(candidate + best - 3, Endian.little) != probe) {
        continue;
      }
      final length = _extendRow(src, view, ip, candidate, end);
      if (length > best) {
        best = length;
        found = ip - candidate;
        if (ip + length >= end) break;
        probe = view.getUint32(ip + best - 3, Endian.little);
      }
    }
    _insertOne(row, tag, ip);
    _nextToUpdate = ip + 1;
    _foundOffset = found;
    return best;
  }

  int _best(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    if (!zstdUse64Bit) return _bestWeb(src, view, ip, lowLimit, end);
    // The row search bounds a candidate by the window as it stands at this
    // position, not at the block's
    final maxDistance = 1 << params.windowLog;
    final floor = _lowestFrom(ip, lowLimit, maxDistance);
    var best = zstdMinMatch - 1;
    var found = 0;
    _insert(view, ip);

    final keyed = _keyTo(view, ip, _rowShift);
    final row = keyed >>> 8;
    final tag = keyed & 0xff;
    final splat = tag * _x01;
    final wordBase = row << (_rowLog - 3);
    var mask = 0;
    for (var w = _words - 1; w >= 0; w--) {
      var chunk = (_tags as Uint64List)[wordBase + w] ^ splat;
      chunk = (((chunk | _x80) - _x01) | chunk) & _x80;
      mask = (mask << 8) | (((chunk * _gather) >>> 56) & 0xff);
    }
    mask = ~mask & _entryMask;

    final head = _tagBytes[(row << _rowLog) ^ _tagByteXor];
    // The masks are literal so the shift counts are provably under 64, which
    // keeps the guarded slow path out of the loop
    var rest =
        ((mask >>> (head & 63)) | (mask << ((_rowEntries - head) & 63))) &
            _entryMask;
    // The first slot of a row is not a candidate
    rest &= ~(1 << ((_rowEntries - head) & _rowMask));
    final base = row << _rowLog;
    var tries = _tries;
    var probe = view.getUint32(ip, Endian.little);
    while (rest != 0 && tries > 0) {
      final low = rest & -rest;
      rest ^= low;
      final candidate = _rows[
              base + ((head + _isolatedTrailingZeroBitCount(low)) & _rowMask)] -
          1;
      // The row runs newest first, so nothing above the window follows
      if (candidate < floor) {
        break;
      }
      tries--;
      // Four bytes ending where the best match does: a candidate that differs
      // there cannot beat it, and this is most of what the search costs
      if (view.getUint32(candidate + best - 3, Endian.little) != probe) {
        continue;
      }
      final length = _extendRow(src, view, ip, candidate, end);
      if (length > best) {
        best = length;
        found = ip - candidate;
        if (ip + length >= end) {
          break;
        }
        probe = view.getUint32(ip + best - 3, Endian.little);
      }
    }

    // The reference inserts the position it searched, so the next search has
    // one position less to fill
    _insertOne(row, tag, ip);
    _nextToUpdate = ip + 1;
    _foundOffset = found;
    return best;
  }

  /// `ZSTD_BtFindBestMatch`: the longest match at [ip], with [_foundOffset] set
  /// to its distance. A position joins the front of its hash's list unsorted
  /// and only takes its place in the tree when a later search reaches it
  int _bestTree(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    _foundOffset = 0;
    if (ip < _nextToUpdate) {
      return 0;
    }
    _updateDubt(view, ip);
    return _searchDubt(src, view, ip, lowLimit, end);
  }

  /// `ZSTD_updateDUBT`
  void _updateDubt(ByteData view, int ip) {
    var at = _nextToUpdate;
    while (at < ip) {
      final slot = _key(view, at);
      final node = ((at + _lift) & _btMask) << 1;
      _chain[node] = _hashTable[slot];
      _chain[node + 1] = _unsorted;
      _hashTable[slot] = at + _lift;
      at++;
    }
    _nextToUpdate = ip;
  }

  /// `ZSTD_DUBT_findBestMatch`: sorts whatever this hash has collected since
  /// the last search through it, then descends for the longest match
  int _searchDubt(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    final slot = _key(view, ip);
    final curr = ip + _lift;
    final reach = 1 << params.windowLog;
    final low = _lowestFrom(ip, lowLimit, reach);
    final windowLow = low + _lift;
    final btLow = _btMask >= curr ? 0 : curr - _btMask;
    final unsortLimit = btLow > windowLow ? btLow : windowLow;

    var candidates = _tries;
    var previous = 0;
    var match = _hashTable[slot];
    while (match > unsortLimit &&
        _chain[((match & _btMask) << 1) + 1] == _unsorted &&
        candidates > 1) {
      _chain[((match & _btMask) << 1) + 1] = previous;
      previous = match;
      match = _chain[(match & _btMask) << 1];
      candidates--;
    }
    // The reference drops a candidate still unsorted here rather than pay for
    // it, which it calls detrimental to ratio and beneficial for speed
    if (match > unsortLimit &&
        _chain[((match & _btMask) << 1) + 1] == _unsorted) {
      final held = (match & _btMask) << 1;
      _chain[held] = 0;
      _chain[held + 1] = 0;
    }

    match = previous;
    while (match != 0) {
      final next = _chain[((match & _btMask) << 1) + 1];
      _sortDubt(src, view, match, lowLimit, end, candidates, unsortLimit);
      match = next;
      candidates++;
    }

    final node = (curr & _btMask) << 1;
    var smaller = node;
    var larger = node + 1;
    var smallerLength = 0;
    var largerLength = 0;
    var best = 0;
    var found = 0;
    // The reference starts the comparison from a code no real offset reaches,
    // so the first match is always taken
    var offBase = 999999999;
    var matchEnd = curr + 9;
    var tries = _tries;
    match = _hashTable[slot];
    _hashTable[slot] = curr;

    while (tries > 0 && match > windowLow) {
      tries--;
      final at = match - _lift;
      final child = (match & _btMask) << 1;
      var length = smallerLength < largerLength ? smallerLength : largerLength;
      length += _extend(src, view, ip + length, at + length, end);
      if (length > best) {
        if (length > matchEnd - match) {
          matchEnd = match + length;
        }
        // A longer match still has to earn the offset bits it costs
        if (4 * (length - best) >
            zstdHighestBit(curr - match + 1) - zstdHighestBit(offBase)) {
          best = length;
          found = ip - at;
          offBase = found + 3;
        }
        if (ip + length == end) {
          break;
        }
      }
      if (src[at + length] < src[ip + length]) {
        _chain[smaller] = match;
        smallerLength = length;
        if (match <= btLow) {
          smaller = -1;
          break;
        }
        smaller = child + 1;
        match = _chain[child + 1];
      } else {
        _chain[larger] = match;
        largerLength = length;
        if (match <= btLow) {
          larger = -1;
          break;
        }
        larger = child;
        match = _chain[child];
      }
    }
    if (smaller >= 0) {
      _chain[smaller] = 0;
    }
    if (larger >= 0) {
      _chain[larger] = 0;
    }
    // Past a match this long every position it covers is reachable through it
    _nextToUpdate = matchEnd - 8 - _lift;
    _foundOffset = found;
    return best;
  }

  /// `ZSTD_insertDUBT1`: puts one position that entered unsorted in its place
  void _sortDubt(Uint8List src, ByteData view, int curr, int lowLimit, int end,
      int tries, int btLow) {
    final ip = curr - _lift;
    // A node outside the data is compared only as far as the segment it sits
    // in reaches, since the reference holds that segment in a buffer of its own
    final iend = ip < prefixStart ? prefixStart : end;
    final reach = 1 << params.windowLog;
    final valid = lowLimit + _lift;
    final windowLow = curr - valid > reach ? curr - reach : valid;
    final node = (curr & _btMask) << 1;
    var smaller = node;
    var larger = node + 1;
    var smallerLength = 0;
    var largerLength = 0;
    var match = _chain[node];

    while (tries > 0 && match > windowLow) {
      tries--;
      final at = match - _lift;
      final child = (match & _btMask) << 1;
      var length = smallerLength < largerLength ? smallerLength : largerLength;
      length += _extend(src, view, ip + length, at + length, iend);
      // Equal to the end of the input, so which side it belongs on is unknown
      if (ip + length == iend) {
        break;
      }
      if (src[at + length] < src[ip + length]) {
        _chain[smaller] = match;
        smallerLength = length;
        if (match <= btLow) {
          smaller = -1;
          break;
        }
        smaller = child + 1;
        match = _chain[child + 1];
      } else {
        _chain[larger] = match;
        largerLength = length;
        if (match <= btLow) {
          larger = -1;
          break;
        }
        larger = child;
        match = _chain[child];
      }
    }
    if (smaller >= 0) {
      _chain[smaller] = 0;
    }
    if (larger >= 0) {
      _chain[larger] = 0;
    }
  }

  /// `ZSTD_updateTree_internal`: catches the tree up to [ip]
  void _fillTree(Uint8List src, ByteData view, int ip, int lowLimit, int end) {
    var at = _nextToUpdate;
    if (at < lowLimit) {
      at = lowLimit;
    }
    while (at < ip) {
      at += _insertTree(src, view, at, ip, lowLimit, end);
    }
    _nextToUpdate = ip;
  }

  /// `ZSTD_insertBt1`: puts one position in the tree and returns how many
  /// positions that covers. A fill skips a repetitive stretch through that
  /// count.
  ///
  /// Every candidate compared becomes a child of the new node on the side it
  /// sorts to, so the descent is the insertion
  int _insertTree(
      Uint8List src, ByteData view, int ip, int target, int lowLimit, int end) {
    final slot = _key(view, ip);
    var held = _hashTable[slot];
    _hashTable[slot] = ip + _lift;

    final node = ((ip + _lift) & _btMask) << 1;
    var smaller = node;
    var larger = node + 1;
    var smallerLength = 0;
    var largerLength = 0;
    // The window is measured at the position the fill is heading for, since
    // only what is still inside it by then is worth keeping
    final reach = 1 << params.windowLog;
    final low = _lowestFrom(target, lowLimit, reach);
    final btLow = ip > _btMask ? ip - _btMask : 0;
    final floor = btLow > lowLimit ? btLow : lowLimit;
    var best = 8;
    var matchEnd = ip + 9;
    var tries = _tries;

    while (tries > 0 && held != 0) {
      final match = held - _lift;
      if (match < low) {
        break;
      }
      tries--;
      final child = (held & _btMask) << 1;
      var length = smallerLength < largerLength ? smallerLength : largerLength;
      length += _extend(src, view, ip + length, match + length, end);
      if (length > best) {
        best = length;
        if (match + length > matchEnd) {
          matchEnd = match + length;
        }
      }
      // Equal to the end of the input, so which side it belongs on is unknown
      if (ip + length == end) {
        break;
      }
      if (src[match + length] < src[ip + length]) {
        _chain[smaller] = held;
        smallerLength = length;
        if (match <= floor) {
          smaller = -1;
          break;
        }
        smaller = child + 1;
        held = _chain[child + 1];
      } else {
        _chain[larger] = held;
        largerLength = length;
        if (match <= floor) {
          larger = -1;
          break;
        }
        larger = child;
        held = _chain[child];
      }
    }

    if (smaller >= 0) {
      _chain[smaller] = 0;
    }
    if (larger >= 0) {
      _chain[larger] = 0;
    }
    var forward = matchEnd - (ip + 8);
    if (best > 384) {
      final positions = best - 384 < 192 ? best - 384 : 192;
      if (positions > forward) {
        forward = positions;
      }
    }
    return forward;
  }

  /// Every match at [ip] worth considering, longest last, written into
  /// [_matchLengths] and [_matchOffBases] and returned as a count.
  ///
  /// `ZSTD_insertBtAndGetAllMatches`: the repeat offsets first, then the tree
  /// search, which inserts [ip] as it descends exactly as [_insertTree] does
  int _allMatches(Uint8List src, ByteData view, int ip, int lowLimit, int end,
      Uint32List rep, bool noLiterals, int longEnough) {
    // A position the tree deliberately skipped past has nothing to offer, and
    // saying so costs one compare where a descent costs hundreds
    if (ip < _nextToUpdate) {
      return 0;
    }
    _fillTree(src, view, ip, lowLimit, end);
    var count = 0;
    final minMatch = _minMatch;
    var best = minMatch - 1;
    // `ZSTD_insertBtAndGetAllMatches` takes this at the position it is called
    // for, and checks both the repeats and the candidates against it. Where a
    // dictionary has expired it is tighter than the bound the block began with
    final reach = 1 << params.windowLog;
    final windowLow = _lowestFrom(ip, lowLimit, reach);

    final last = noLiterals ? 4 : 3;
    for (var code = noLiterals ? 1 : 0; code < last; code++) {
      final offset = code == 3 ? rep[0] - 1 : rep[code];
      final at = ip - offset;
      // A repeat that stays inside the data is bounded by the window alone; one
      // reaching into a dictionary may not straddle the two
      if (offset <= 0 ||
          at < windowLow ||
          (at < prefixStart && _spansDictionary(at))) {
        continue;
      }
      final mask = minMatch == 3 ? 0xffffff : 0xffffffff;
      if (view.getUint32(at, Endian.little) & mask !=
          view.getUint32(ip, Endian.little) & mask) {
        continue;
      }
      final length =
          minMatch + _extend(src, view, ip + minMatch, at + minMatch, end);
      if (length > best) {
        best = length;
        _matchOffBases[count] = code - (noLiterals ? 1 : 0) + 1;
        _matchLengths[count] = length;
        count++;
        if (length > longEnough || ip + length >= end) {
          return count;
        }
      }
    }

    if (minMatch == 3 && best < 3) {
      var at = _nextShort < lowLimit ? lowLimit : _nextShort;
      while (at < ip) {
        _short[_shortKey(view, at)] = at + 1;
        at++;
      }
      _nextShort = ip;
      // `ZSTD_insertAndFindFirstIndexHash3` fills up to but not including this
      // position, leaving the next call to insert it. At the end of a block
      // there is no next call, and the position stays out of the table
      final held = _short[_shortKey(view, ip)];
      final match = held - 1;
      // A three byte match further back than this is never worth its offset
      if (held != 0 && match >= windowLow && ip - match < 1 << 18) {
        final length = _extend(src, view, ip, match, end);
        if (length >= 3) {
          best = length;
          _matchOffBases[0] = ip - match + 3;
          _matchLengths[0] = length;
          count = 1;
          if (length > longEnough || ip + length >= end) {
            _nextToUpdate = ip + 1;
            return 1;
          }
        }
      }
    }

    final slot = _key(view, ip);
    var held = _hashTable[slot];
    _hashTable[slot] = ip + _lift;

    final node = ((ip + _lift) & _btMask) << 1;
    var smaller = node;
    var larger = node + 1;
    var smallerLength = 0;
    var largerLength = 0;
    var matchEnd = ip + 9;
    final btLow = ip > _btMask ? ip - _btMask : 0;
    final floor = btLow > lowLimit ? btLow : lowLimit;
    var tries = _tries;

    while (tries-- > 0 && held != 0) {
      final match = held - _lift;
      if (match < windowLow) {
        break;
      }
      final child = (held & _btMask) << 1;
      var length = smallerLength < largerLength ? smallerLength : largerLength;
      length += _extend(src, view, ip + length, match + length, end);
      if (length > best) {
        if (match + length > matchEnd) {
          matchEnd = match + length;
        }
        best = length;
        _matchOffBases[count] = ip - match + 3;
        _matchLengths[count] = length;
        count++;
        if (length > _optMax || ip + length >= end) {
          break;
        }
      }
      if (src[match + length] < src[ip + length]) {
        _chain[smaller] = held;
        smallerLength = length;
        if (match <= floor) {
          smaller = -1;
          break;
        }
        smaller = child + 1;
        held = _chain[child + 1];
      } else {
        _chain[larger] = held;
        largerLength = length;
        if (match <= floor) {
          larger = -1;
          break;
        }
        larger = child;
        held = _chain[child];
      }
    }

    if (smaller >= 0) {
      _chain[smaller] = 0;
    }
    if (larger >= 0) {
      _chain[larger] = 0;
    }
    // Everything a match already covers is reachable through it, so the tree
    // starts again past its end rather than at the next byte
    final skip = matchEnd - 8;
    _nextToUpdate = skip > ip + 1 ? skip : ip + 1;
    return count;
  }

  @pragma('vm:prefer-inline')
  void _newRep(int from, int into, int offBase, bool noLiterals) {
    final a = from * 3;
    final b = into * 3;
    if (offBase > 3) {
      _optRep[b + 2] = _optRep[a + 1];
      _optRep[b + 1] = _optRep[a];
      _optRep[b] = offBase - 3;
      return;
    }
    final code = offBase - 1 + (noLiterals ? 1 : 0);
    if (code == 0) {
      _optRep[b] = _optRep[a];
      _optRep[b + 1] = _optRep[a + 1];
      _optRep[b + 2] = _optRep[a + 2];
      return;
    }
    final held = code == 3 ? _optRep[a] - 1 : _optRep[a + code];
    _optRep[b + 2] = code >= 2 ? _optRep[a + 1] : _optRep[a + 2];
    _optRep[b + 1] = _optRep[a];
    _optRep[b] = held;
  }

  /// `btultra2` spends a whole pass over the first block just to collect
  /// statistics, then throws the result away and starts again with them.
  /// `ZSTD_initStats_ultra`
  void _parseOptimal(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    // `ZSTD_compressBlock_btultra2` asks for `window.dictLimit == lowLimit`
    // and for the parse to start on `dictLimit` itself, so a frame given a
    // dictionary, and a job given a prefix, both skip the pass
    if (params.depth >= 3 &&
        _prices.litLengthSum == 0 &&
        !_ext &&
        start == prefixStart) {
      _repScratch[0] = rep[0];
      _repScratch[1] = rep[1];
      _repScratch[2] = rep[2];
      _optimalPass(src, view, start, end, lowLimit, store, _repScratch);
      store.reset();
      reset();
    }
    _optimalPass(src, view, start, end, lowLimit, store, rep);
  }

  /// The optimal parse. Moves forward filling a table of the cheapest way to
  /// reach every byte of the lookahead, then follows the chain of predecessors
  /// back and emits it. `ZSTD_compressBlock_opt_generic`
  void _optimalPass(Uint8List src, ByteData view, int start, int end,
      int lowLimit, ZstdSequenceStore store, Uint32List rep) {
    final limit = end - 8;
    final prices = _prices;
    prices.level = params.depth > 2 ? 2 : params.depth;
    prices.rescale(src, start, end);
    _optLdm.begin(ldm, end - start);
    final sufficient =
        params.targetLength < _optMax - 1 ? params.targetLength : _optMax - 1;
    var anchor = start;
    var ip = start == _prefixFrom(lowLimit) ? start + 1 : start;
    if (_nextToUpdate < lowLimit) {
      _nextToUpdate = lowLimit;
    }
    // `nextToUpdate3` is a local of `ZSTD_compressBlock_opt_generic`, so the
    // three byte table starts each pass where the tree has reached rather than
    // where the last pass left it
    _nextShort = _nextToUpdate;

    while (ip < limit) {
      var lastPos = 0;
      var cur = 0;
      var lastMlen = 0;
      var lastLitlen = 0;
      var lastOff = 0;
      var taken = false;

      final litlen = ip - anchor;
      var found = _allMatches(
          src, view, ip, lowLimit, end, rep, litlen == 0, sufficient);
      found = _optLdm.process(_matchLengths, _matchOffBases, found, ip - start,
          end - ip, _minMatch);
      if (found == 0) {
        ip++;
        continue;
      }

      _optMlen[0] = 0;
      _optLitlen[0] = litlen;
      _optPrice[0] = prices.litLengthPrice(litlen);
      _optRep[0] = rep[0];
      _optRep[1] = rep[1];
      _optRep[2] = rep[2];

      final maxLength = _matchLengths[found - 1];
      if (maxLength > sufficient) {
        lastLitlen = 0;
        lastMlen = maxLength;
        lastOff = _matchOffBases[found - 1];
        cur = 0;
        lastPos = maxLength;
        taken = true;
      }

      if (!taken) {
        var pos = 1;
        for (; pos < _minMatch; pos++) {
          _optPrice[pos] = zstdPriceMax;
          _optMlen[pos] = 0;
          _optLitlen[pos] = litlen + pos;
        }
        for (var n = 0; n < found; n++) {
          final offBase = _matchOffBases[n];
          final reach = _matchLengths[n];
          if (prices.level == 0) {
            for (; pos <= reach; pos++) {
              _optMlen[pos] = pos;
              _optOff[pos] = offBase;
              _optLitlen[pos] = 0;
              _optPrice[pos] = _optPrice[0] +
                  prices.matchPrice(offBase, pos) +
                  prices.litLengthPrice(0);
            }
          } else {
            final offsetPrice = prices.matchOffsetPrice(offBase);
            for (; pos <= reach; pos++) {
              _optMlen[pos] = pos;
              _optOff[pos] = offBase;
              _optLitlen[pos] = 0;
              _optPrice[pos] = _optPrice[0] +
                  offsetPrice +
                  prices.matchLengthPrice(pos) +
                  prices.litLengthPrice(0);
            }
          }
        }
        lastPos = pos - 1;
        _optPrice[pos] = zstdPriceMax;

        for (cur = 1; cur <= lastPos; cur++) {
          final inr = ip + cur;
          final grown = _optLitlen[cur - 1] + 1;
          final withLiteral = _optPrice[cur - 1] +
              prices.literalsPrice(src, inr - 1, 1) +
              prices.litLengthPrice(grown) -
              prices.litLengthPrice(grown - 1);
          if (withLiteral <= _optPrice[cur]) {
            final heldPrice = _optPrice[cur];
            final heldMlen = _optMlen[cur];
            final heldOff = _optOff[cur];
            final heldLitlen = _optLitlen[cur];
            _optPrice[cur] = withLiteral;
            _optMlen[cur] = _optMlen[cur - 1];
            _optOff[cur] = _optOff[cur - 1];
            _optLitlen[cur] = grown;
            final a = (cur - 1) * 3;
            final b = cur * 3;
            _optRep[b] = _optRep[a];
            _optRep[b + 1] = _optRep[a + 1];
            _optRep[b + 2] = _optRep[a + 2];
            // A match followed by exactly one literal can beat both the match
            // alone and a longer literal run, and only this look ahead finds it
            final oneMore = prices.litLengthPrice(1) - prices.litLengthPrice(0);
            if (prices.level >= 1 &&
                heldLitlen == 0 &&
                oneMore < 0 &&
                inr < end) {
              final one =
                  heldPrice + prices.literalsPrice(src, inr, 1) + oneMore;
              final more = withLiteral +
                  prices.literalsPrice(src, inr, 1) +
                  prices.litLengthPrice(grown + 1) -
                  prices.litLengthPrice(grown);
              if (one < more && one < _optPrice[cur + 1]) {
                final prev = cur - heldMlen;
                _optMlen[cur + 1] = heldMlen;
                _optOff[cur + 1] = heldOff;
                _newRep(prev, cur + 1, heldOff, _optLitlen[prev] == 0);
                _optLitlen[cur + 1] = 1;
                _optPrice[cur + 1] = one;
                if (lastPos < cur + 1) {
                  lastPos = cur + 1;
                }
              }
            }
          }

          if (_optLitlen[cur] == 0) {
            _newRep(cur - _optMlen[cur], cur, _optOff[cur],
                _optLitlen[cur - _optMlen[cur]] == 0);
          }

          if (inr > limit) {
            continue;
          }
          if (cur == lastPos) {
            break;
          }
          if (prices.level == 0 &&
              _optPrice[cur + 1] <= _optPrice[cur] + (zstdPriceOne >> 1)) {
            continue;
          }

          final base = _optPrice[cur] + prices.litLengthPrice(0);
          final at = cur * 3;
          _repHere[0] = _optRep[at];
          _repHere[1] = _optRep[at + 1];
          _repHere[2] = _optRep[at + 2];
          found = _allMatches(src, view, inr, lowLimit, end, _repHere,
              _optLitlen[cur] == 0, sufficient);
          found = _optLdm.process(_matchLengths, _matchOffBases, found,
              inr - start, end - inr, _minMatch);
          if (found == 0) {
            continue;
          }

          final longest = _matchLengths[found - 1];
          if (longest > sufficient ||
              cur + longest >= _optMax ||
              inr + longest >= end) {
            lastMlen = longest;
            lastOff = _matchOffBases[found - 1];
            lastLitlen = 0;
            lastPos = cur + longest;
            taken = true;
            break;
          }

          for (var n = 0; n < found; n++) {
            final offBase = _matchOffBases[n];
            final reach = _matchLengths[n];
            final from = n > 0 ? _matchLengths[n - 1] + 1 : _minMatch;
            if (prices.level == 0) {
              for (var mlen = reach; mlen >= from; mlen--) {
                final pos = cur + mlen;
                final price = base + prices.matchPrice(offBase, mlen);
                if (pos > lastPos || price < _optPrice[pos]) {
                  while (lastPos < pos) {
                    lastPos++;
                    _optPrice[lastPos] = zstdPriceMax;
                    _optLitlen[lastPos] = 1;
                  }
                  _optMlen[pos] = mlen;
                  _optOff[pos] = offBase;
                  _optLitlen[pos] = 0;
                  _optPrice[pos] = price;
                } else {
                  break;
                }
              }
            } else {
              final offsetPrice = prices.matchOffsetPrice(offBase);
              for (var mlen = reach; mlen >= from; mlen--) {
                final pos = cur + mlen;
                final price =
                    base + offsetPrice + prices.matchLengthPrice(mlen);
                if (pos > lastPos || price < _optPrice[pos]) {
                  while (lastPos < pos) {
                    lastPos++;
                    _optPrice[lastPos] = zstdPriceMax;
                    _optLitlen[lastPos] = 1;
                  }
                  _optMlen[pos] = mlen;
                  _optOff[pos] = offBase;
                  _optLitlen[pos] = 0;
                  _optPrice[pos] = price;
                }
              }
            }
          }
          _optPrice[lastPos + 1] = zstdPriceMax;
        }

        if (!taken) {
          lastMlen = _optMlen[lastPos];
          lastLitlen = _optLitlen[lastPos];
          lastOff = _optOff[lastPos];
          cur = lastPos - lastMlen;
        }
      }

      if (lastMlen == 0) {
        ip += lastPos;
        continue;
      }

      if (lastLitlen == 0) {
        _newRep(cur, _optSize - 1, lastOff, _optLitlen[cur] == 0);
        rep[0] = _optRep[(_optSize - 1) * 3];
        rep[1] = _optRep[(_optSize - 1) * 3 + 1];
        rep[2] = _optRep[(_optSize - 1) * 3 + 2];
      } else {
        rep[0] = _optRep[lastPos * 3];
        rep[1] = _optRep[lastPos * 3 + 1];
        rep[2] = _optRep[lastPos * 3 + 2];
        cur -= lastLitlen;
      }

      // The path is written back over the table, turning stretches into
      // sequences: a match followed by literals becomes literals then a match
      final storeEnd = cur + 2;
      var storeStart = storeEnd;
      var walk = cur;
      _optMlen[storeStart] = lastMlen;
      _optOff[storeStart] = lastOff;
      _optLitlen[storeStart] = lastLitlen;
      while (true) {
        final mlen = _optMlen[walk];
        final llen = _optLitlen[walk];
        final off = _optOff[walk];
        _optLitlen[storeStart] = llen;
        if (mlen == 0) {
          break;
        }
        storeStart--;
        _optMlen[storeStart] = mlen;
        _optOff[storeStart] = off;
        _optLitlen[storeStart] = llen;
        walk -= llen + mlen;
      }

      for (var at = storeStart; at <= storeEnd; at++) {
        final llen = _optLitlen[at];
        final mlen = _optMlen[at];
        final offBase = _optOff[at];
        if (mlen == 0) {
          ip = anchor + llen;
          continue;
        }
        prices.record(src, anchor, llen, offBase, mlen);
        store.add(src, anchor, llen, offBase, mlen - zstdMatchLengthFloor);
        anchor += llen + mlen;
        ip = anchor;
      }
      prices.setBases();
    }

    store.finish(src, anchor, end);
  }

  /// Puts every position below [ip] in its row, so a later search sees them.
  /// Past a long match only the first and last positions go in, the reference's
  /// own 384, 96 and 32
  @pragma('vm:prefer-inline')
  void _insert(ByteData view, int ip) {
    final at = _nextToUpdate;
    if (_skipping || at == ip) {
      _nextToUpdate = ip;
      return;
    }
    _insertRun(view, at, ip);
  }

  /// The insert loop, kept out of line so it does not make every value
  /// the search holds call clobbered
  @pragma('vm:never-inline')
  void _insertRun(ByteData view, int from, int ip) {
    var at = from;
    if (ip - at > 384) {
      _fill(view, at, at + 96);
      at = ip - 32;
    }
    _fill(view, at, ip);
    _nextToUpdate = ip;
  }

  /// Takes the next slot of [row], cycling backwards over everything but the
  /// first, which the reference keeps its head in
  @pragma('vm:prefer-inline')
  void _insertOne(int row, int tag, int at) {
    final base = row << _rowLog;
    var head = (_tagBytes[base ^ _tagByteXor] - 1) & _rowMask;
    if (head == 0) {
      head = _rowMask;
    }
    _tagBytes[base ^ _tagByteXor] = head;
    _rows[base | head] = at + 1;
    _tagBytes[(base | head) ^ _tagByteXor] = tag;
  }

  @pragma('vm:prefer-inline')
  void _fill(ByteData view, int from, int ip) {
    var at = from;
    while (at < ip) {
      final keyed = _keyTo(view, at, _rowShift);
      final row = keyed >>> 8;
      _insertOne(row, keyed & 0xff, at);
      at++;
    }
  }

  static int _extendBack(
      Uint8List src, int ip, int match, int anchor, int lowLimit) {
    var back = 0;
    while (ip - back > anchor &&
        match - back > lowLimit &&
        src[ip - back - 1] == src[match - back - 1]) {
      back++;
    }
    return back;
  }

  /// The same match length count, inlined into the row search where it is most
  /// of the work and the row search has registers to spare. Only there:
  /// pointing every caller here was -0.10% and doubled `_parseChained`
  @pragma('vm:prefer-inline')
  int _extendRow(Uint8List src, ByteData view, int a, int b, int end) {
    if (!zstdUse64Bit) return zstdWebCount(src, view, a, b, end);
    var length = 0;
    while (a + length + 8 <= end) {
      final left = view.getUint64(a + length, Endian.little);
      final right = view.getUint64(b + length, Endian.little);
      if (left != right) {
        final diff = left ^ right;
        return length + (_trailingZeroBitCount(diff) >> 3);
      }
      length += 8;
    }
    if (a + length + 4 <= end) {
      final left = view.getUint32(a + length, Endian.little);
      final right = view.getUint32(b + length, Endian.little);
      if (left != right) {
        return length + (_trailingZeroBitCount(left ^ right) >> 3);
      }
      length += 4;
    }
    while (a + length < end && src[a + length] == src[b + length]) {
      length++;
    }
    return length;
  }

  /// How many bytes past [a] and [b] are the same. Eight at a time, since a
  /// pair of reads costs about what one costs and this is the hottest loop of
  /// the whole encoder
  int _extend(Uint8List src, ByteData view, int a, int b, int end) {
    if (!zstdUse64Bit) return zstdWebCount(src, view, a, b, end);
    var length = 0;
    while (a + length + 8 <= end) {
      final left = view.getUint64(a + length, Endian.little);
      final right = view.getUint64(b + length, Endian.little);
      if (left != right) {
        final diff = left ^ right;
        return length + (_trailingZeroBitCount(diff) >> 3);
      }
      length += 8;
    }
    if (a + length + 4 <= end) {
      final left = view.getUint32(a + length, Endian.little);
      final right = view.getUint32(b + length, Endian.little);
      if (left != right) {
        return length + (_trailingZeroBitCount(left ^ right) >> 3);
      }
      length += 4;
    }
    while (a + length < end && src[a + length] == src[b + length]) {
      length++;
    }
    return length;
  }

  @pragma('vm:prefer-inline')
  int _shortKey(ByteData view, int at) => zstdUse64Bit
      ? (((view.getUint32(at, Endian.little) << 8) * _shortPrime) &
              0xffffffff) >>>
          (32 - _shortLog)
      : zstdWebMultiply32(
              view.getUint32(at, Endian.little) << 8, _shortPrime) >>>
          (32 - _shortLog);

  /// The key of the position at [at], in the table's own width
  @pragma('vm:prefer-inline')
  int _key(ByteData view, int at) => zstdUse64Bit
      ? (view.getUint64(at, Endian.little) * _keyMul) >>> _shift
      : zstdWebKey(view, at, _keyMul, _shift);

  /// The same key kept to [shift] bits from the top, for a table of its own
  /// width or for a row index with its tag below it
  @pragma('vm:prefer-inline')
  int _keyTo(ByteData view, int at, int shift) => zstdUse64Bit
      ? (view.getUint64(at, Endian.little) * _keyMul) >>> shift
      : zstdWebKey(view, at, _keyMul, shift);

  /// The same key from a multiplier and a shift the parse already holds, so a
  /// parse that hashes three times a pass does not reload two fields each time
  @pragma('vm:prefer-inline')
  static int _keyWith(ByteData view, int at, int keyMul, int shift) =>
      zstdUse64Bit
          ? (view.getUint64(at, Endian.little) * keyMul) >>> (shift & 63)
          : zstdWebKey(view, at, keyMul, shift);

  @pragma('vm:prefer-inline')
  static int _longKey(ByteData view, int at, int shift) => zstdUse64Bit
      ? (view.getUint64(at, Endian.little) * _longPrime) >>> shift
      : zstdWebKey(view, at, 8, shift);

  @pragma('vm:prefer-inline')
  static bool _same8(ByteData view, int a, int b) => zstdUse64Bit
      ? view.getUint64(a, Endian.little) == view.getUint64(b, Endian.little)
      : zstdWebSame8(view, a, b);
}

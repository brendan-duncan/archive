import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_bit_writer.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_fse_encoder.dart';
import 'zstd_fse_predefined.dart';
import 'zstd_level_params.dart';
import 'zstd_web.dart';

class ZstdSequencesEncoderException extends ArchiveException {
  ZstdSequencesEncoderException(super.message);
  @override
  String toString() => 'ZstdSequencesEncoderException: $message';
}

/// Literal length code per length, up to 63; above that it is the highest set
/// bit plus nineteen
final Uint8List zstdLiteralsLengthCodes = Uint8List.fromList(const [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, //
  22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, //
  24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
]);

/// Match length code per length above the minimum, up to 127; above that it is
/// the highest set bit plus thirty six
final Uint8List zstdMatchLengthCodes = Uint8List.fromList(const [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
  32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37, //
  38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39, //
  40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, //
  41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, //
  42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, //
  42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
]);

/// `kInverseProbabilityLog256`: the cost in 256ths of a bit of a symbol whose
/// probability is the index over 256
final Uint16List _inverseLog256 = Uint16List.fromList(const [
  0, 2048, 1792, 1642, 1536, 1453, 1386, 1329, 1280, 1236, 1197, 1162, //
  1130, 1100, 1073, 1047, 1024, 1001, 980, 960, 941, 923, 906, 889, //
  874, 859, 844, 830, 817, 804, 791, 779, 768, 756, 745, 734, //
  724, 714, 704, 694, 685, 676, 667, 658, 650, 642, 633, 626, //
  618, 610, 603, 595, 588, 581, 574, 567, 561, 554, 548, 542, //
  535, 529, 523, 517, 512, 506, 500, 495, 489, 484, 478, 473, //
  468, 463, 458, 453, 448, 443, 438, 434, 429, 424, 420, 415, //
  411, 407, 402, 398, 394, 390, 386, 382, 377, 373, 370, 366, //
  362, 358, 354, 350, 347, 343, 339, 336, 332, 329, 325, 322, //
  318, 315, 311, 308, 305, 302, 298, 295, 292, 289, 286, 282, //
  279, 276, 273, 270, 267, 264, 261, 258, 256, 253, 250, 247, //
  244, 241, 239, 236, 233, 230, 228, 225, 222, 220, 217, 215, //
  212, 209, 207, 204, 202, 199, 197, 194, 192, 190, 187, 185, //
  182, 180, 178, 175, 173, 171, 168, 166, 164, 162, 159, 157, //
  155, 153, 151, 149, 146, 144, 142, 140, 138, 136, 134, 132, //
  130, 128, 126, 123, 121, 119, 117, 115, 114, 112, 110, 108, //
  106, 104, 102, 100, 98, 96, 94, 93, 91, 89, 87, 85, //
  83, 82, 80, 78, 76, 74, 73, 71, 69, 67, 66, 64, //
  62, 61, 59, 57, 55, 54, 52, 50, 49, 47, 46, 44, //
  42, 41, 39, 37, 36, 34, 33, 31, 30, 28, 26, 25, //
  23, 22, 20, 19, 17, 16, 14, 13, 11, 10, 8, 7, //
  5, 4, 2, 1,
]);

@pragma('vm:prefer-inline')
int zstdLiteralsLengthCode(int length) => length < 64
    ? zstdLiteralsLengthCodes[length]
    : zstdHighestBitFast(length) + 19;

@pragma('vm:prefer-inline')
int zstdMatchLengthCode(int base) =>
    base < 128 ? zstdMatchLengthCodes[base] : zstdHighestBitFast(base) + 36;

/// The sequences of one block, plus the literals they leave behind.
///
/// An offset is held the way the format writes it: one to three name a repeat
/// offset, anything above is the real distance plus three
class ZstdSequenceStore {
  final Uint8List literals;
  final ByteData _view;
  Uint8List? _held;
  ByteData? _heldView;
  int literalsLength = 0;

  /// Four words a sequence: the literal run, the match length above the
  /// format's floor, the stored offset, and the codes the encoder packs into
  /// the fourth. One array rather than four keeps a single base pointer and a
  /// single length live through the loops over them
  final Uint32List seq;
  int count = 0;

  /// `ZSTD_maxNbSeq`: a level whose shortest match is three bytes can store one
  /// sequence per three bytes of block, where every other level takes four
  ZstdSequenceStore(int blockSizeMax, {int minMatch = 4})
      : this._(Uint8List(blockSizeMax + _wildcopy), blockSizeMax,
            minMatch == 3 ? 3 : 4);

  ZstdSequenceStore._(Uint8List buffer, int blockSizeMax, int divider)
      : literals = buffer,
        _view = ByteData.sublistView(buffer),
        seq = Uint32List((blockSizeMax ~/ divider + 2) * _stride);

  void reset() {
    literalsLength = 0;
    count = 0;
  }

  void add(Uint8List src, int from, int length, int offsetBaseValue,
      int matchBaseValue) {
    if (length > 0) {
      // A literal run is usually a handful of bytes, where two moves that may
      // write past the run cost less than a call that has to be exact.
      // `litLimit_w`: near the end of the input there is nothing to over read
      // into, so the exact copy is the only safe one
      if (zstdUse64Bit &&
          length <= 16 &&
          from + 16 <= src.length &&
          literalsLength + 16 <= literals.length) {
        final view = _viewOf(src);
        _view.setUint64(
            literalsLength, view.getUint64(from, Endian.little), Endian.little);
        if (length > 8) {
          _view.setUint64(literalsLength + 8,
              view.getUint64(from + 8, Endian.little), Endian.little);
        }
      } else {
        literals.setRange(literalsLength, literalsLength + length, src, from);
      }
      literalsLength += length;
    }
    final at = count << 2;
    seq[at] = length;
    seq[at + 1] = matchBaseValue;
    seq[at + 2] = offsetBaseValue;
    count++;
  }

  @pragma('vm:prefer-inline')
  ByteData _viewOf(Uint8List src) {
    if (!identical(src, _held)) {
      _held = src;
      _heldView = ByteData.sublistView(src);
    }
    return _heldView!;
  }

  /// `ZSTD_countSeqStoreLiteralsBytes`: the literals `[from...to)` consume
  int literalsIn(int from, int to) {
    var total = 0;
    for (var at = from * _stride; at < to * _stride; at += _stride) {
      total += seq[at];
    }
    return total;
  }

  /// `ZSTD_countSeqStoreMatchBytes`: the bytes matches cover over `[from...to)`
  int matchesIn(int from, int to) {
    var total = 0;
    for (var at = from * _stride; at < to * _stride; at += _stride) {
      total += seq[at + 1] + _matchFloor;
    }
    return total;
  }

  /// The tail of the block, which no match covers
  void finish(Uint8List src, int from, int end) {
    final length = end - from;
    if (length > 0) {
      literals.setRange(literalsLength, literalsLength + length, src, from);
      literalsLength += length;
    }
  }
}

/// Words a sequence takes in the store, and where its codes sit inside the
/// last of them. A code fits in six bits and a count of extra bits in five
/// `WILDCOPY_OVERLENGTH`, the room a copy that writes in whole words may run
/// past the run it was asked for
const _wildcopy = 32;

const _stride = 4;

/// `MINMATCH`, which a stored match length is held above
const _matchFloor = 3;

/// Where each field sits in a packed code word.
const _mlShift = 6;
const _ofShift = 12;
const _llBitsShift = 18;
const _mlBitsShift = 23;

/// Replaces the reference's error return, which its unsigned comparisons
/// treat as a cost above any other
const _costError = 1099511627776;

const _modePredefined = 0;
const _modeRle = 1;
const _modeCompressed = 2;
const _modeRepeat = 3;

/// One of the three tables across the blocks of a frame. A description that has
/// not reached the decoder yet lives in [spare], and only a block that is kept
/// swaps it in
class _TableSlot {
  ZstdFseCTable live;
  ZstdFseCTable spare;

  /// Whether the decoder holds a table this one could ask it to repeat
  bool ready = false;
  bool nextReady = false;

  /// `FSE_repeat_valid` rather than `FSE_repeat_check`: only a dictionary gives
  /// the decoder a table trusted without weighing it first
  bool trusted = false;
  bool nextTrusted = false;
  bool swap = false;

  _TableSlot(int maxLog, int maxSymbolCount)
      : live = ZstdFseCTable(maxLog, maxSymbolCount),
        spare = ZstdFseCTable(maxLog, maxSymbolCount);

  ZstdFseCTable get inUse => swap ? spare : live;

  void commit() {
    if (swap) {
      final held = live;
      live = spare;
      spare = held;
    }
    ready = nextReady;
    trusted = nextTrusted;
  }
}

/// Writes the sequences section: the count, how each of the three tables is
/// described, those descriptions, and the interleaved bitstream
class ZstdSequencesEncoder {
  /// Sized to the mask the counting loop indexes them by, not to the codes
  /// they hold. The bound check goes away that way
  final Uint32List _llCounts = Uint32List(64);
  final Uint32List _ofCounts = Uint32List(32);
  final Uint32List _mlCounts = Uint32List(64);
  final Int16List _normalized = Int16List(zstdMatchLengthCodeMax + 1);
  final Uint8List _spread = Uint8List(1 << zstdMatchLengthLogMax);
  final Uint16List _scratch = Uint16List(zstdMatchLengthCodeMax + 1);
  final Uint32List _cumulative = Uint32List(zstdMatchLengthCodeMax + 2);

  /// `FSE_NCOUNTBOUND`, where a description is written only to be measured
  final Uint8List _ncountScratch = Uint8List(512);

  final _TableSlot _llSlot =
      _TableSlot(zstdLiteralsLengthLogMax, zstdLiteralsLengthCodeMax + 1);
  final _TableSlot _ofSlot =
      _TableSlot(zstdOffsetLogMax, zstdOffsetCodeMax + 1);
  final _TableSlot _mlSlot =
      _TableSlot(zstdMatchLengthLogMax, zstdMatchLengthCodeMax + 1);

  /// The level's parse, which decides whether a table is picked by weighing
  /// what each would cost or by the cheap rules the levels below `lazy` use
  int strategy = zstdStrategyLazy;

  /// How each table was described by the last [encode] or [estimate]
  int llMode = 0;
  int ofMode = 0;
  int mlMode = 0;

  /// Writes the section for `store[from...to]` at [at], returning the bytes it
  /// took. A partition of a split block passes its own range, everything else
  /// the whole store
  int encode(Uint8List out, int at, ZstdSequenceStore store,
      [int from = 0, int to = -1]) {
    final last = to < 0 ? store.count : to;
    final count = last - from;
    _holdSlots();
    var write = at;
    if (count < 128) {
      out[write++] = count;
    } else if (count < 0x7f00) {
      out[write++] = (count >> 8) + 128;
      out[write++] = count & 0xff;
    } else {
      out[write++] = 255;
      out[write++] = (count - 0x7f00) & 0xff;
      out[write++] = (count - 0x7f00) >> 8;
    }
    if (count == 0) {
      return write - at;
    }

    _countCodes(store, from, last);
    final modesAt = write++;
    write += _describeTables(out, write, store, count, last);
    out[modesAt] = (llMode << 6) | (ofMode << 4) | (mlMode << 2);

    return _writeBitstream(out, write, store, from, last) - at;
  }

  /// `ZSTD_estimateBlockSize_sequences`: the cost of this section, tables
  /// and all, without writing the bitstream. The splitter compares partitions
  /// with this, so it has to be the reference's estimate rather than the real
  /// encode. It decides where the block is cut
  int estimate(Uint8List scratch, ZstdSequenceStore store, int from, int to) {
    final count = to - from;
    final header = 2 + (count >= 128 ? 1 : 0) + (count >= 0x7f00 ? 1 : 0);
    if (count == 0) {
      return header;
    }
    _holdSlots();
    _countCodes(store, from, to);
    var total = header + _describeTables(scratch, 0, store, count, to);
    total += _symbolCost(
        llMode,
        _llCounts,
        zstdLiteralsLengthCodeMax,
        _llSlot,
        zstdPredefinedLiteralsLength,
        zstdPredefinedLiteralsLengthLog,
        zstdLiteralsLengthExtraBits,
        count);
    total += _symbolCost(ofMode, _ofCounts, zstdOffsetCodeMax, _ofSlot,
        zstdPredefinedOffset, zstdPredefinedOffsetLog, null, count);
    total += _symbolCost(
        mlMode,
        _mlCounts,
        zstdMatchLengthCodeMax,
        _mlSlot,
        zstdPredefinedMatchLength,
        zstdPredefinedMatchLengthLog,
        zstdMatchLengthExtraBits,
        count);
    return total;
  }

  /// `ZSTD_estimateBlockSize_symbolType`, in bytes: the codes through whichever
  /// table was chosen for them, plus their extra bits. An offset code
  /// is itself the count of its extra bits, so [extraBits] may be null
  static int _symbolCost(
      int mode,
      Uint32List counts,
      int maxSymbol,
      _TableSlot slot,
      Int16List predefined,
      int predefinedLog,
      Uint8List? extraBits,
      int count) {
    var top = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      if (counts[s] != 0) {
        top = s;
      }
    }
    int bits;
    if (mode == _modeRle) {
      bits = 0;
    } else if (mode == _modePredefined) {
      bits = _crossEntropyCost(predefined, predefinedLog, counts, top);
    } else {
      final through = _cost(slot.inUse, counts, top);
      if (through < 0) {
        return count * 10;
      }
      bits = through >> 8;
    }
    for (var s = 0; s <= top; s++) {
      final seen = counts[s];
      if (seen != 0) {
        bits += seen * (extraBits == null ? s : extraBits[s]);
      }
    }
    return bits >> 3;
  }

  /// A block with no sequences describes no table, so committing it must leave
  /// the ones the decoder holds exactly as they are.
  /// `ZSTD_entropyCompressSeqStore` copies the whole of `prevEntropy->fse` over
  /// on `nbSeq == 0`, which includes the repeat mode of each table and not only
  /// whether one is there
  void _holdSlots() {
    for (final slot in [_llSlot, _ofSlot, _mlSlot]) {
      slot.swap = false;
      slot.nextReady = slot.ready;
      slot.nextTrusted = slot.trusted;
    }
  }

  /// Codes and their counts in one pass, since the tables need both and a
  /// second pass over every sequence was an eighth of the encode
  void _countCodes(ZstdSequenceStore store, int from, int last) {
    _llCounts.fillRange(0, _llCounts.length, 0);
    _ofCounts.fillRange(0, _ofCounts.length, 0);
    _mlCounts.fillRange(0, _mlCounts.length, 0);
    // Both code tables are lazily built statics, and reading one costs a call
    // to its initialiser guard, which clobbers the whole loop's registers
    final llTable = zstdLiteralsLengthCodes;
    final mlTable = zstdMatchLengthCodes;
    final llBitsTable = zstdLiteralsLengthExtraBits;
    final mlBitsTable = zstdMatchLengthExtraBits;
    final seq = store.seq;
    final end = last * _stride;
    for (var at = from * _stride; at < end; at += _stride) {
      final llLength = seq[at];
      final ll =
          llLength < 64 ? llTable[llLength] : zstdHighestBitFast(llLength) + 19;
      final mlLength = seq[at + 1];
      final ml = mlLength < 128
          ? mlTable[mlLength]
          : zstdHighestBitFast(mlLength) + 36;
      final of = zstdHighestBitFast(seq[at + 2]);
      seq[at + 3] = ll |
          (ml << _mlShift) |
          (of << _ofShift) |
          (llBitsTable[ll] << _llBitsShift) |
          (mlBitsTable[ml] << _mlBitsShift);
      // A code cannot reach the mask, so the mask costs one instruction and
      // removes the bound check the counter would otherwise need
      _llCounts[ll & 63]++;
      _ofCounts[of & 31]++;
      _mlCounts[ml & 63]++;
    }
  }

  /// Describes all three tables at [at] and returns what they took, leaving how
  /// each was chosen in [llMode], [ofMode] and [mlMode]
  int _describeTables(
      Uint8List out, int at, ZstdSequenceStore store, int count, int last) {
    // The last sequence's state is written into the bitstream rather than
    // coded, so `ZSTD_buildCTable` leaves it out of the distribution it
    // describes
    final tail = store.seq[((last - 1) << 2) + 3];
    var write = at;
    final ll = _writeTable(
        out,
        write,
        _llCounts,
        count,
        zstdLiteralsLengthCodeMax,
        zstdLiteralsLengthLogMax,
        zstdPredefinedLiteralsLength,
        zstdPredefinedLiteralsLengthLog,
        _llSlot,
        tail & 63);
    write += ll.size;
    final of = _writeTable(
        out,
        write,
        _ofCounts,
        count,
        zstdOffsetCodeMax,
        zstdOffsetLogMax,
        zstdPredefinedOffset,
        zstdPredefinedOffsetLog,
        _ofSlot,
        (tail >> _ofShift) & 63);
    write += of.size;
    final ml = _writeTable(
        out,
        write,
        _mlCounts,
        count,
        zstdMatchLengthCodeMax,
        zstdMatchLengthLogMax,
        zstdPredefinedMatchLength,
        zstdPredefinedMatchLengthLog,
        _mlSlot,
        (tail >> _mlShift) & 63);
    write += ml.size;
    llMode = ll.mode;
    ofMode = of.mode;
    mlMode = ml.mode;
    return write - at;
  }

  /// Chooses how one table is described, writes the description, and leaves the
  /// encoding table ready in [slot]
  ({int mode, int size}) _writeTable(
      Uint8List out,
      int at,
      Uint32List counts,
      int count,
      int maxSymbol,
      int maxLog,
      Int16List predefined,
      int predefinedLog,
      _TableSlot slot,
      int lastCode) {
    slot.swap = false;
    slot.nextReady = false;
    slot.nextTrusted = false;
    var largest = 0;
    var most = 0;
    var top = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      final seen = counts[s];
      if (seen == 0) {
        continue;
      }
      top = s;
      if (seen > most) {
        most = seen;
        largest = s;
      }
    }

    // The offset alphabet reaches past the predefined table, and nothing else
    // does, so this is the reference's `isDefaultAllowed`
    final predefinedTop = predefined.length - 1;
    final allowed = top <= predefinedTop;

    if (most == count) {
      // Two sequences do not pay for the byte an RLE description costs
      if (allowed && count <= 2) {
        return _takePredefined(predefined, predefinedTop, predefinedLog, slot);
      }
      out[at] = largest;
      _buildRle(slot.spare, largest);
      slot.swap = true;
      return (mode: _modeRle, size: 1);
    }

    if (strategy < zstdStrategyLazy) {
      // Only a table from a dictionary is taken unweighed here. That is
      // what `FSE_repeat_valid` means
      if (allowed && slot.trusted && count < _staticRepeatMax) {
        slot.nextReady = true;
        slot.nextTrusted = true;
        return (mode: _modeRepeat, size: 0);
      }
      final least = ((1 << predefinedLog) * (9 - strategy)) >> 3;
      if (allowed && (count < least || most < count >> (predefinedLog - 1))) {
        return _takePredefined(predefined, predefinedTop, predefinedLog, slot);
      }
      final log = zstdOptimalTableLog(maxLog, count, top);
      _describe(counts, count, top, log, lastCode);
      final size = zstdWriteNCount(out, at, _normalized, top, log);
      slot.spare.build(_normalized, top, log, _spread, _scratch, _cumulative);
      slot.swap = true;
      slot.nextReady = true;
      return (mode: _modeCompressed, size: size);
    }

    // From `lazy` up the three ways of describing a table are weighed against
    // each other in bits rather than picked by a rule of thumb
    final log = zstdOptimalTableLog(maxLog, count, top);
    final basic = allowed
        ? _crossEntropyCost(predefined, predefinedLog, counts, top)
        : _costError;
    final held = slot.ready ? _cost(slot.live, counts, top) : -1;
    final repeat = held < 0 ? _costError : held >> 8;
    final fresh = (_ncountCost(counts, count, top, log) << 3) +
        _entropyCost(counts, top, count);

    if (allowed && basic <= repeat && basic <= fresh) {
      return _takePredefined(predefined, predefinedTop, predefinedLog, slot);
    }
    if (repeat <= fresh) {
      slot.nextReady = true;
      slot.nextTrusted = slot.trusted;
      return (mode: _modeRepeat, size: 0);
    }
    _describe(counts, count, top, log, lastCode);
    final size = zstdWriteNCount(out, at, _normalized, top, log);
    slot.spare.build(_normalized, top, log, _spread, _scratch, _cumulative);
    slot.swap = true;
    slot.nextReady = true;
    return (mode: _modeCompressed, size: size);
  }

  /// `staticFse_nbSeq_max`, above which a dictionary's table is weighed like
  /// any other rather than taken outright
  static const _staticRepeatMax = 1000;

  /// `ZSTD_NCountCost`: what describing these counts would take. The
  /// description finally written takes less, since that one leaves out the
  /// last sequence's symbol
  int _ncountCost(Uint32List counts, int count, int top, int log) {
    zstdNormalizeCount(_normalized, counts, count, top, log,
        useLowProbCount: count >= 2048);
    return zstdWriteNCount(_ncountScratch, 0, _normalized, top, log);
  }

  /// `ZSTD_crossEntropyCost`, in bits: what these counts cost through a table
  /// normalized to [accuracyLog]
  static int _crossEntropyCost(
      Int16List norm, int accuracyLog, Uint32List counts, int top) {
    final shift = 8 - accuracyLog;
    var cost = 0;
    for (var s = 0; s <= top; s++) {
      final points = norm[s];
      cost += counts[s] * _inverseLog256[(points != -1 ? points : 1) << shift];
    }
    return cost >> 8;
  }

  /// `ZSTD_entropyCost`, in bits: the bound a table of its own would reach,
  /// used instead of building one and measuring it
  static int _entropyCost(Uint32List counts, int top, int total) {
    var cost = 0;
    for (var s = 0; s <= top; s++) {
      final seen = counts[s];
      var points = (256 * seen) ~/ total;
      if (seen != 0 && points == 0) {
        points = 1;
      }
      cost += seen * _inverseLog256[points];
    }
    return cost >> 8;
  }

  /// Normalises [counts] into `_normalized` the way `ZSTD_buildCTable` does,
  /// which is without the last sequence's own symbol
  void _describe(Uint32List counts, int count, int top, int log, int lastCode) {
    var total = count;
    final held = counts[lastCode];
    if (held > 1) {
      counts[lastCode] = held - 1;
      total--;
    }
    final ok = zstdNormalizeCount(_normalized, counts, total, top, log,
        useLowProbCount: total >= 2048);
    counts[lastCode] = held;
    if (!ok) {
      throw ZstdSequencesEncoderException('One code takes every sequence');
    }
  }

  ({int mode, int size}) _takePredefined(Int16List predefined,
      int predefinedTop, int predefinedLog, _TableSlot slot) {
    slot.spare.build(predefined, predefinedTop, predefinedLog, _spread,
        _scratch, _cumulative);
    slot.swap = true;
    return (mode: _modePredefined, size: 0);
  }

  /// What these counts cost through [table], in 256ths of a bit, or -1 when the
  /// table gives a symbol they need no probability at all
  static int _cost(ZstdFseCTable table, Uint32List counts, int top) {
    if (table.maxSymbol < top) {
      return -1;
    }
    final bad = table.badCost;
    var total = 0;
    for (var s = 0; s <= top; s++) {
      final seen = counts[s];
      if (seen == 0) {
        continue;
      }
      final each = table.bitCost(s);
      if (each >= bad) {
        return -1;
      }
      total += seen * each;
    }
    return total;
  }

  /// Keeps the tables this block described, which only a block that is written
  /// out may do
  /// `ZSTD_loadCEntropy`: the three tables in a dictionary become the ones
  /// the decoder already holds, so a first block can repeat rather than
  /// describe them. The offset table is built over every code the format has,
  /// since a table that stops short cannot price the codes above it
  /// The reference trusts a dictionary's offset table for one block only, since
  /// past that the offsets in the data can outgrow the codes it holds
  void dropOffsetTrust() {
    _ofSlot.trusted = false;
  }

  void loadDictionary(ZstdDictionary dictionary) {
    if (!dictionary.hasEntropy) {
      return;
    }
    _load(_llSlot, dictionary, zstdSlotLiteralsLength,
        dictionary.maxSymbols[zstdSlotLiteralsLength]);
    _load(_ofSlot, dictionary, zstdSlotOffset, zstdOffsetCodeMax);
    _load(_mlSlot, dictionary, zstdSlotMatchLength,
        dictionary.maxSymbols[zstdSlotMatchLength]);
  }

  /// The three tables from a dictionary, for the optimal parse to price
  /// its first block from. Null once nothing trusted is left
  ZstdFseCTable? get dictionaryLitLengths =>
      _llSlot.trusted ? _llSlot.live : null;
  ZstdFseCTable? get dictionaryOffsets => _ofSlot.trusted ? _ofSlot.live : null;
  ZstdFseCTable? get dictionaryMatchLengths =>
      _mlSlot.trusted ? _mlSlot.live : null;

  void _load(_TableSlot slot, ZstdDictionary dictionary, int which, int top) {
    slot.live.build(dictionary.counts[which], top, dictionary.logs[which],
        _spread, _scratch, _cumulative);
    slot.ready = true;
    slot.trusted = true;
  }

  void commit() {
    _llSlot.commit();
    _ofSlot.commit();
    _mlSlot.commit();
  }

  void _buildRle(ZstdFseCTable table, int symbol) {
    for (var s = 0; s <= symbol; s++) {
      _normalized[s] = 0;
    }
    _normalized[symbol] = 1;
    table.build(_normalized, symbol, 0, _spread, _scratch, _cumulative);
  }

  int _writeBitstream(
      Uint8List out, int at, ZstdSequenceStore store, int from, int to) {
    final writer = ZstdBitWriter(ByteData.sublistView(out), at);
    final last = to - 1;
    final llTable = _llSlot.inUse;
    final ofTable = _ofSlot.inUse;
    final mlTable = _mlSlot.inUse;
    final seq = store.seq;

    final top = last * _stride;
    final tail = seq[top + 3];
    var mlState = mlTable.initialState((tail >> _mlShift) & 63);
    var ofState = ofTable.initialState((tail >> _ofShift) & 63);
    var llState = llTable.initialState(tail & 63);
    writer.add(seq[top], (tail >> _llBitsShift) & 31);
    writer.add(seq[top + 1], (tail >> _mlBitsShift) & 31);
    writer.flush();
    writer.add(seq[top + 2], (tail >> _ofShift) & 63);
    writer.flush();

    // The container holds sixty four bits and the three states take at most
    // twenty six of them, so a sequence usually needs one flush, not three
    final floor = from * _stride;
    for (var at = top - _stride; at >= floor; at -= _stride) {
      final packed = seq[at + 3];
      final ofCode = (packed >> _ofShift) & 63;
      final llBits = (packed >> _llBitsShift) & 31;
      final mlBits = (packed >> _mlBitsShift) & 31;
      final extra = ofCode + mlBits + llBits;
      ofState = ofTable.encode(writer, ofState, ofCode);
      mlState = mlTable.encode(writer, mlState, (packed >> _mlShift) & 63);
      llState = llTable.encode(writer, llState, packed & 63);
      if (extra >= 31) {
        writer.flush();
      }
      writer.add(seq[at], llBits);
      writer.add(seq[at + 1], mlBits);
      if (extra > 56) {
        writer.flush();
      }
      writer.add(seq[at + 2], ofCode);
      writer.flush();
    }

    writer.add(mlState, mlTable.accuracyLog);
    writer.flush();
    writer.add(ofState, ofTable.accuracyLog);
    writer.flush();
    writer.add(llState, llTable.accuracyLog);
    writer.flush();
    return writer.close();
  }
}

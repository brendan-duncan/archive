import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_fse.dart';
import 'zstd_fse_predefined.dart';
import 'zstd_literals.dart';
import 'zstd_window.dart';

class ZstdSequencesException extends ArchiveException {
  ZstdSequencesException(super.message);
  @override
  String toString() => 'ZstdSequencesException: $message';
}

const _holdsNothing = 0;
const _holdsPredefined = 1;
const _holdsBuilt = 2;

/// Everything about a sequences section except the table rows and the loop that
/// reads them. Those two are written once per bit container width.
///
/// The three tables persist across the blocks of a frame. A repeat mode block
/// refers back to them, so one instance lives for one frame
abstract class ZstdSequencesBase {
  static const builtBases = [
    zstdLiteralsLengthTableBase,
    zstdOffsetTableBase,
    zstdMatchLengthTableBase,
  ];
  static const _predefinedBases = [
    zstdPredefinedLiteralsLengthTableBase,
    zstdPredefinedOffsetTableBase,
    zstdPredefinedMatchLengthTableBase,
  ];

  /// Which base each slot's states currently point at
  final Int32List bases = Int32List(3);

  /// Accuracy log per slot, and what the slot currently holds, so a predefined
  /// table is only copied in when it is not already there
  final Int32List logs = Int32List(3);
  final Int32List _holds = Int32List(3);

  static const _maxSymbol = [
    zstdLiteralsLengthCodeMax,
    zstdOffsetCodeMax,
    zstdMatchLengthCodeMax,
  ];
  static const _maxLog = [
    zstdLiteralsLengthLogMax,
    zstdOffsetLogMax,
    zstdMatchLengthLogMax,
  ];
  static const _predefinedLog = [
    zstdPredefinedLiteralsLengthLog,
    zstdPredefinedOffsetLog,
    zstdPredefinedMatchLengthLog,
  ];

  final Int16List _counts = Int16List(zstdMatchLengthCodeMax + 1);

  /// Scratch for a table build, allocated once per frame rather than per block
  final Uint8List spread = Uint8List(1 << zstdMatchLengthLogMax);
  final Uint16List nextState = Uint16List(zstdMatchLengthCodeMax + 1);

  /// Writes one table's rows at [base], reading the value each symbol stands
  /// for from the slot's own baseline and extra bit tables
  void buildTable(
      int base, int slot, Int16List counts, int maxSymbol, int accuracyLog);

  /// A single row for a table that codes one symbol only
  void setRleTable(int base, int slot, int symbol);

  /// Bytes the loop's container reads at once, and so the shortest bitstream it
  /// can be pointed at directly
  int get minStreamBytes;

  /// Zero bytes below a bitstream too short to fill the container
  late final Uint8List pad = Uint8List(minStreamBytes * 2);
  late final ByteData padView = ByteData.sublistView(pad);

  /// Decode and execution in one loop, returning the new window position.
  /// [view] covers [src], and [at] with [length] is the bitstream inside it
  int run(
      Uint8List src,
      ByteData view,
      int at,
      int length,
      ZstdLiterals literals,
      ZstdWindow window,
      Uint32List rep,
      int count,
      int blockSizeMax);

  /// Called from the constructor of every subclass, once its rows exist
  void buildPredefinedTables() {
    zstdBuildPredefinedTables(buildTable);
  }

  void reset() {
    _holds[0] = _holdsNothing;
    _holds[1] = _holdsNothing;
    _holds[2] = _holdsNothing;
  }

  /// Rebuilds the dictionary's three tables, so a first block may repeat them.
  /// They are rebuilt rather than referenced because a later block writes over
  /// them in place
  void loadDictionary(ZstdDictionary dictionary) {
    for (var slot = 0; slot < 3; slot++) {
      buildTable(builtBases[slot], slot, dictionary.counts[slot],
          dictionary.maxSymbols[slot], dictionary.logs[slot]);
      bases[slot] = builtBases[slot];
      logs[slot] = dictionary.logs[slot];
      _holds[slot] = _holdsBuilt;
    }
  }

  /// Reads the sequences section spanning [start] to [end] and writes the
  /// block's output into [window]
  void decode(Uint8List src, int start, int end, ZstdLiterals literals,
      ZstdWindow window, Uint32List rep, int blockSizeMax) {
    if (start >= end) {
      _sequencesSectionIsEmpty();
    }
    var at = start;
    final first = src[at];
    final int count;
    if (first < 128) {
      count = first;
      at += 1;
    } else if (first < 255) {
      if (at + 2 > end) {
        _sequenceCountIsTruncated();
      }
      count = ((first - 128) << 8) + src[at + 1];
      at += 2;
    } else {
      if (at + 3 > end) {
        _sequenceCountIsTruncated();
      }
      count = src[at + 1] + (src[at + 2] << 8) + 0x7f00;
      at += 3;
    }

    if (count == 0) {
      // `ZSTD_decodeSeqHeaders`: no sequence means the section ends here, and
      // anything still in the block is extraneous
      if (at != end) {
        _extraneousDataAfterTheCount();
      }
      _copyLiterals(literals, window, blockSizeMax);
      return;
    }

    if (at >= end) {
      _compressionModesByteIs();
    }
    final modes = src[at];
    at += 1;
    if (modes & 3 != 0) {
      _reservedBitsInThe();
    }
    at += _readTable(src, at, end, zstdSlotLiteralsLength, (modes >> 6) & 3);
    at += _readTable(src, at, end, zstdSlotOffset, (modes >> 4) & 3);
    at += _readTable(src, at, end, zstdSlotMatchLength, (modes >> 2) & 3);

    final length = end - at;
    if (length <= 0) {
      _sequenceBitstreamIsMissing();
    }

    final int position;
    final least = minStreamBytes;
    try {
      if (length >= least) {
        position = run(src, ByteData.sublistView(src), at, length, literals,
            window, rep, count, blockSizeMax);
      } else {
        pad.fillRange(0, least, 0);
        pad.setRange(least, least + length, src, at);
        position = run(pad, padView, least, length, literals, window, rep,
            count, blockSizeMax);
      }
    } on RangeError catch (error) {
      _outsideBlock(error);
    }
    window.position = position;
  }

  void _copyLiterals(
      ZstdLiterals literals, ZstdWindow window, int blockSizeMax) {
    final size = literals.length;
    if (size > blockSizeMax) {
      _blockOutputIsLarger();
    }
    final at = window.position;
    // Where a block has no sequence to place them, so the literals are moved
    // down from the room reserved above the output rather than decoded again
    window.buffer.setRange(
        at, at + size, window.buffer, at + blockSizeMax + zstdCopySlack);
    window.position = at + size;
  }

  /// Returns the bytes the table description occupied
  int _readTable(Uint8List src, int at, int end, int slot, int mode) {
    final base = builtBases[slot];
    switch (mode) {
      case zstdModePredefined:
        bases[slot] = _predefinedBases[slot];
        logs[slot] = _predefinedLog[slot];
        _holds[slot] = _holdsPredefined;
        return 0;
      case zstdModeRle:
        if (at >= end) {
          _rleTableSymbolIs();
        }
        final symbol = src[at];
        if (symbol > _maxSymbol[slot]) {
          _rleSymbolTooLarge(symbol);
        }
        setRleTable(base, slot, symbol);
        bases[slot] = base;
        logs[slot] = 0;
        _holds[slot] = _holdsBuilt;
        return 1;
      case zstdModeCompressed:
        final distribution = readFseDistribution(
            src, at, end, _counts, _maxSymbol[slot],
            maxAccuracyLog: _maxLog[slot]);
        buildTable(base, slot, _counts, distribution.maxSymbol,
            distribution.accuracyLog);
        bases[slot] = base;
        logs[slot] = distribution.accuracyLog;
        _holds[slot] = _holdsBuilt;
        return distribution.bytesRead;
      default:
        if (_holds[slot] == _holdsNothing) {
          _repeatModeWithNo();
        }
        return 0;
    }
  }
}

/// Every throw here lives out of line: inline, the exception's own
/// construction puts an allocation and a call into a function that is
/// otherwise straight-line work, and costs registers where nothing throws
@pragma('vm:never-inline')
Never _sequencesSectionIsEmpty() =>
    throw ZstdSequencesException('Sequences section is empty');

@pragma('vm:never-inline')
Never _sequenceCountIsTruncated() =>
    throw ZstdSequencesException('Sequence count is truncated');

@pragma('vm:never-inline')
Never _extraneousDataAfterTheCount() => throw ZstdSequencesException(
    'Extraneous data present in the sequences section');

@pragma('vm:never-inline')
Never _compressionModesByteIs() =>
    throw ZstdSequencesException('Compression modes byte is missing');

@pragma('vm:never-inline')
Never _reservedBitsInThe() =>
    throw ZstdSequencesException('Reserved bits in the compression modes');

@pragma('vm:never-inline')
Never _sequenceBitstreamIsMissing() =>
    throw ZstdSequencesException('Sequence bitstream is missing');

@pragma('vm:never-inline')
Never _blockOutputIsLarger() =>
    throw ZstdSequencesException('Block output is larger than a block');

@pragma('vm:never-inline')
Never _rleTableSymbolIs() =>
    throw ZstdSequencesException('RLE table symbol is missing');

@pragma('vm:never-inline')
Never _repeatModeWithNo() =>
    throw ZstdSequencesException('Repeat mode with no table to repeat');

@pragma('vm:never-inline')
Never _outsideBlock(Object error) =>
    throw ZstdSequencesException('Sequences reach outside the block: $error');

@pragma('vm:never-inline')
Never _rleSymbolTooLarge(int symbol) =>
    throw ZstdSequencesException('RLE table symbol $symbol is too large');

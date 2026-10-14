import 'dart:typed_data';

import '../../util/archive_exception.dart';

import 'zstd_constants.dart';
import 'zstd_fse.dart';
import 'zstd_huffman.dart';

class ZstdDictionaryException extends ArchiveException {
  ZstdDictionaryException(super.message);
  @override
  String toString() => 'ZstdDictionaryException: $message';
}

/// A parsed zstd dictionary, ready to be passed to a decoder.
///
/// Parsing is done once here rather than once per frame. Anything that is not a
/// formatted dictionary is taken as raw content, the way the reference decoder
/// takes it
class ZstdDictionary {
  /// Zero for a raw content dictionary, which no frame can name
  final int id;

  /// What matches reach back into, placed before the output of every frame
  final Uint8List content;

  /// The whole buffer this was read from, headers and all. The reference sizes
  /// a frame's parameters by this rather than by the content alone
  final int sourceSize;

  /// The three offsets a frame starts with
  final Uint32List repeatOffsets;

  /// False for a raw content dictionary, whose tables a first block cannot
  /// repeat
  final bool hasEntropy;

  final ZstdHuffmanTable huffman;

  /// The tree as it was described. An encoder builds from it
  final Uint8List huffmanWeights;

  /// The three sequence distributions, by slot. These are kept rather than the
  /// rows they build into, so the row layout stays a matter for the decoder
  final List<Int16List> counts;
  final List<int> maxSymbols;
  final List<int> logs;

  /// `ZSTD_compress_insertDictionary` drops one under eight bytes, the decoder
  /// keeps it
  bool get usableForEncode => sourceSize >= 8 && content.isNotEmpty;

  ZstdDictionary._(
      this.id,
      this.content,
      this.sourceSize,
      this.repeatOffsets,
      this.hasEntropy,
      this.huffman,
      this.huffmanWeights,
      this.counts,
      this.maxSymbols,
      this.logs);

  factory ZstdDictionary(List<int> data) {
    try {
      return _read(data);
    } on ZstdDictionaryException {
      rethrow;
    } on ArchiveException catch (error) {
      throw ZstdDictionaryException(error.message);
    }
  }

  static ZstdDictionary _read(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (bytes.length < 8 || _uint32At(bytes, 0) != zstdDictionaryMagic) {
      return ZstdDictionary._(
          0,
          bytes,
          bytes.length,
          Uint32List.fromList(zstdInitialRepeatOffsets),
          false,
          ZstdHuffmanTable(),
          Uint8List(0), const [], const [], const []);
    }

    final end = bytes.length;
    final huffman = ZstdHuffmanTable();
    final scratch = ZstdHuffmanScratch();
    var at = 8;
    at += readHuffmanTable(bytes, at, end, huffman, scratch);
    final huffmanWeights =
        Uint8List.sublistView(scratch.weights, 0, huffman.symbolCount);

    final counts = [
      for (var i = 0; i < 3; i++) Int16List(zstdMatchLengthCodeMax + 1)
    ];
    final maxSymbols = [0, 0, 0];
    final logs = [0, 0, 0];
    // A dictionary stores the three tables offset first, the decoder wants them
    // by slot
    for (final slot in const [
      zstdSlotOffset,
      zstdSlotMatchLength,
      zstdSlotLiteralsLength
    ]) {
      final distribution = readFseDistribution(
          bytes, at, end, counts[slot], _maxSymbol[slot],
          maxAccuracyLog: _maxLog[slot]);
      maxSymbols[slot] = distribution.maxSymbol;
      logs[slot] = distribution.accuracyLog;
      at += distribution.bytesRead;
    }

    if (at + 12 > end) {
      throw ZstdDictionaryException('Repeat offsets are truncated');
    }
    final content = Uint8List.sublistView(bytes, at + 12);
    final repeatOffsets = Uint32List(zstdRepeatOffsetCount);
    for (var i = 0; i < zstdRepeatOffsetCount; i++) {
      final value = _uint32At(bytes, at + (i << 2));
      if (value == 0 || value > content.length) {
        throw ZstdDictionaryException(
            'Repeat offset $value reaches outside the dictionary content');
      }
      repeatOffsets[i] = value;
    }

    return ZstdDictionary._(
        _uint32At(bytes, 4),
        content,
        bytes.length,
        repeatOffsets,
        true,
        huffman,
        Uint8List.fromList(huffmanWeights),
        counts,
        maxSymbols,
        logs);
  }

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

  static int _uint32At(Uint8List bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
}

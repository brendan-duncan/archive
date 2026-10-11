import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_huffman_encoder.dart';
import 'zstd_web.dart';

/// What a tree description plus its streams has to beat before the literals
/// are worth coding at all, `hSize + 12 >= srcSize` in the reference
const _tableSlack = 12;

/// The reference's own probe for a block that is unlikely to compress: it
/// counts this many bytes at each end rather than the whole block
const _probeSize = 4096;
const _probeFrom = _probeSize * 10;

/// Writes the literals section of a block: stored, one repeated byte, a
/// Huffman tree and its streams, or those streams against the tree the last
/// block left with the decoder, whichever comes out smallest
class ZstdLiteralsEncoder {
  ZstdHuffmanEncoder _live = ZstdHuffmanEncoder();
  ZstdHuffmanEncoder _spare = ZstdHuffmanEncoder();
  final Uint32List _counts = Uint32List(zstdHuffmanSymbolCount);

  /// `HIST_count_parallel`: four tallies so that a run of one byte does not
  /// serialise on a single counter, summed once at the end
  final Uint32List _tallies = Uint32List(4 * zstdHuffmanSymbolCount);

  /// Whether the decoder holds a tree this block could ask it to reuse
  bool _ready = false;
  bool _nextReady = false;
  bool _swap = false;

  /// `ZSTD_minLiteralsToCompress` and `ZSTD_minGain`'s shift for this level.
  /// A tree from a dictionary lowers the floor to six, since reusing it
  /// costs the block nothing to describe
  int minSize = 64;

  /// `ZSTD_literalsCompressionIsDisabled`: the `--fast` levels store their
  /// literals as they stand
  bool disabled = false;
  bool _trusted = false;
  bool _nextTrusted = false;

  int get _floor => _trusted ? 6 : minSize;
  int gainLog = 6;

  /// `HUF_flags_preferRepeat`: below `lazy` a short section takes the tree the
  /// decoder holds without weighing it against one of its own
  bool cheapRepeat = false;

  /// `HUF_flags_optimalDepth`: from `btultra` up the tree's depth is searched
  /// for rather than estimated
  set optimalDepth(bool on) {
    _live.optimalDepth = on;
    _spare.optimalDepth = on;
  }

  /// Takes a dictionary's tree as the one the decoder already holds, so the
  /// first block can send its literals without describing a tree
  void loadDictionary(Uint8List weights, int log) {
    _live.loadWeights(weights, log);
    _ready = true;
    // `HUF_repeat_valid` only for a tree that covers every byte value: anything
    // less and a block still has to weigh it against one of its own
    var whole = weights.length == 256;
    for (var s = 0; whole && s < weights.length; s++) {
      whole = weights[s] != 0;
    }
    _trusted = whole;
  }

  /// The tree the decoder holds, which the optimal parse prices its first
  /// block from when a dictionary put one there
  ZstdHuffmanEncoder? get dictionaryTree => _ready ? _live : null;

  /// Keeps the tree this block described, which only a block that is written
  /// out may do
  void commit() {
    if (_swap) {
      final held = _live;
      _live = _spare;
      _spare = held;
    }
    _ready = _nextReady;
    _trusted = _nextTrusted;
  }

  /// Writes `src[start...end]` at [at] and returns the bytes it took
  int encode(Uint8List out, int at, Uint8List src, int start, int end,
      {bool suspect = false}) {
    _swap = false;
    _nextReady = _ready;
    _nextTrusted = _trusted;
    final size = end - start;
    if (disabled || size < _floor) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }

    // A block whose literals barely broke into sequences is probably not
    // compressible, and two samples say so for a sixteenth of the counting
    if (suspect && size >= _probeFrom) {
      // Two counts, not one over both samples: the reference takes the largest
      // of each end and adds them. That is not the largest of their sum
      final seen = _probe(src, start) + _probe(src, end - _probeSize);
      if (seen <= ((2 * _probeSize) >> 7) + 4) {
        return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
      }
    }

    final headerFor = 3 + (size >= 1024 ? 1 : 0) + (size >= 16384 ? 1 : 0);
    // `HUF_flags_preferRepeat` with a table that covers every byte: the tree
    // the decoder holds is taken before this block is even counted
    if (cheapRepeat && size <= 1024 && _trusted) {
      return _writeTreeless(out, at, src, start, end, headerFor, size);
    }
    final largest = _count(src, start, end);
    if (largest == size) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRle);
    }
    // `HUF_compress_internal`: literals this flat cannot pay for a tree, and
    // finding that out by building one costs most of an incompressible block
    if (largest <= (size >> 7) + 4) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }
    final headerSize = 3 + (size >= 1024 ? 1 : 0) + (size >= 16384 ? 1 : 0);
    final held = _ready ? _bitsThrough(_live) : -1;
    if (cheapRepeat && size <= 1024 && held >= 0) {
      return _writeTreeless(out, at, src, start, end, headerSize, size);
    }
    if (!_spare.build(_counts, size)) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }
    final tableSize = _spare.writeTable(out, at + headerSize);
    if (tableSize < 0) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }

    // The tree the decoder holds costs no description, so it wins whenever it
    // codes these about as tightly, and one this dear is not worth sending
    final cramped = tableSize + _tableSlack >= size;
    if (held >= 0 &&
        (cramped || (held >> 3) <= tableSize + (_bitsThrough(_spare) >> 3))) {
      return _writeTreeless(out, at, src, start, end, headerSize, size);
    }
    if (cramped) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }

    // `singleStream`: a table from the dictionary and a three byte header
    // put the whole section in one stream regardless of its size
    _spare.oneStream = _trusted && headerSize == 3;
    final streamsSize = _spare.encodeLiterals(
        out, at + headerSize + tableSize, src, start, end);
    if (streamsSize < 0) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }

    final coded = tableSize + streamsSize;
    if (coded >= size - ((size >> gainLog) + 2)) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }
    _swap = true;
    _nextReady = true;
    // A tree of our own is only `HUF_repeat_check`: the next block still has to
    // weigh it rather than take it outright
    _nextTrusted = false;
    _writeCodedHeader(out, at, size, coded, headerSize, zstdLiteralsCompressed,
        one: _spare.oneStream);
    return headerSize + coded;
  }

  /// `ZSTD_buildBlockEntropyStats_literals` and
  /// `ZSTD_estimateBlockSize_literal` together: the size of this run, tree
  /// and all, without writing any of it. The block splitter compares partitions
  /// with this, and its rules are not [encode]'s: no probe, no minimum gain,
  /// and a floor of `COMPRESS_LITERALS_SIZE_MIN`, which a valid tree lowers as
  /// [encode]'s is
  int estimate(Uint8List scratch, Uint8List src, int start, int end) {
    final size = end - start;
    if (size <= (_trusted ? 6 : 63)) {
      return size;
    }
    final largest = _count(src, start, end);
    if (largest == size) {
      return 1;
    }
    if (largest <= (size >> 7) + 4) {
      return size;
    }
    final held = _ready ? _bitsThrough(_live) : -1;
    if (!_spare.build(_counts, size)) {
      return size;
    }
    final described = _spare.writeTable(scratch, 0);
    if (described < 0) {
      return size;
    }
    final fresh = _bitsThrough(_spare) >> 3;
    if (held >= 0) {
      final reuse = held >> 3;
      if (reuse < size &&
          (reuse <= described + fresh || described + 12 >= size)) {
        return _sectionSize(reuse, size);
      }
    }
    if (fresh + described >= size) {
      return size;
    }
    return _sectionSize(fresh + described, size);
  }

  /// Four streams have a six byte jump table the single stream form does not
  static int _sectionSize(int coded, int size) =>
      coded +
      (size < zstdFourStreamsFrom ? 0 : 6) +
      3 +
      (size >= 1024 ? 1 : 0) +
      (size >= 16384 ? 1 : 0);

  /// Codes the literals through the tree the decoder holds, describing nothing
  int _writeTreeless(Uint8List out, int at, Uint8List src, int start, int end,
      int headerSize, int size) {
    _live.oneStream = _trusted && headerSize == 3;
    final coded = _live.encodeLiterals(out, at + headerSize, src, start, end);
    if (coded < 0 || coded >= size - ((size >> gainLog) + 2)) {
      return _writeStored(out, at, src, start, size, zstdLiteralsRaw);
    }
    _writeCodedHeader(out, at, size, coded, headerSize, zstdLiteralsTreeless,
        one: _live.oneStream);
    return headerSize + coded;
  }

  /// `HIST_count_simple` over one sample, returning its largest tally
  int _probe(Uint8List src, int at) {
    _counts.fillRange(0, zstdHuffmanSymbolCount, 0);
    var largest = 0;
    for (var i = 0; i < _probeSize; i++) {
      final seen = ++_counts[src[at + i]];
      if (seen > largest) {
        largest = seen;
      }
    }
    return largest;
  }

  /// Fills [_counts] and returns the largest tally
  int _count(Uint8List src, int start, int end) {
    _tallies.fillRange(0, _tallies.length, 0);
    final view = ByteData.sublistView(src);
    var at = start;
    final limit = end - 8;
    while (at <= limit) {
      if (!zstdUse64Bit) {
        final low = view.getUint32(at, Endian.little);
        final high = view.getUint32(at + 4, Endian.little);
        _tallies[low & 0xff]++;
        _tallies[0x100 + ((low >>> 8) & 0xff)]++;
        _tallies[0x200 + ((low >>> 16) & 0xff)]++;
        _tallies[0x300 + (low >>> 24)]++;
        _tallies[high & 0xff]++;
        _tallies[0x100 + ((high >>> 8) & 0xff)]++;
        _tallies[0x200 + ((high >>> 16) & 0xff)]++;
        _tallies[0x300 + (high >>> 24)]++;
        at += 8;
        continue;
      }
      final word = view.getUint64(at, Endian.little);
      _tallies[word & 0xff]++;
      _tallies[0x100 + ((word >>> 8) & 0xff)]++;
      _tallies[0x200 + ((word >>> 16) & 0xff)]++;
      _tallies[0x300 + ((word >>> 24) & 0xff)]++;
      _tallies[(word >>> 32) & 0xff]++;
      _tallies[0x100 + ((word >>> 40) & 0xff)]++;
      _tallies[0x200 + ((word >>> 48) & 0xff)]++;
      _tallies[0x300 + (word >>> 56)]++;
      at += 8;
    }
    while (at < end) {
      _tallies[src[at++]]++;
    }
    var largest = 0;
    for (var s = 0; s < zstdHuffmanSymbolCount; s++) {
      final total = _tallies[s] +
          _tallies[0x100 + s] +
          _tallies[0x200 + s] +
          _tallies[0x300 + s];
      _counts[s] = total;
      if (total > largest) {
        largest = total;
      }
    }
    return largest;
  }

  /// What these literals cost through [tree] in bits, or -1 when it has no code
  /// for one of them. Truncating it to bytes before weighing decides a tie
  int _bitsThrough(ZstdHuffmanEncoder tree) {
    var total = 0;
    for (var s = 0; s < zstdHuffmanSymbolCount; s++) {
      final seen = _counts[s];
      if (seen == 0) {
        continue;
      }
      final width = tree.widths[s];
      if (width == 0) {
        return -1;
      }
      total += seen * width;
    }
    return total;
  }

  static int _writeStored(
      Uint8List out, int at, Uint8List src, int start, int size, int type) {
    final headerSize = 1 + (size > 31 ? 1 : 0) + (size > 4095 ? 1 : 0);
    if (headerSize == 1) {
      out[at] = type | (size << 3);
    } else {
      final format = headerSize == 2 ? 1 : 3;
      var value = type | (format << 2) | (size << 4);
      for (var i = 0; i < headerSize; i++) {
        out[at + i] = value & 0xff;
        value >>= 8;
      }
    }
    if (type == zstdLiteralsRle) {
      out[at + headerSize] = src[start];
      return headerSize + 1;
    }
    if (size > 0) {
      out.setRange(at + headerSize, at + headerSize + size, src, start);
    }
    return headerSize + size;
  }

  /// Two bits of type, two of size format, then the two sizes, which together
  /// reach forty bits and so are written by arithmetic rather than shifts
  static void _writeCodedHeader(
      Uint8List out, int at, int size, int coded, int headerSize, int type,
      {bool one = false}) {
    final int format;
    final int bits;
    if (headerSize == 3) {
      format = size < zstdFourStreamsFrom || one ? 0 : 1;
      bits = 10;
    } else if (headerSize == 4) {
      format = 2;
      bits = 14;
    } else {
      format = 3;
      bits = 18;
    }
    var value = type + (format << 2) + size * 16;
    var scale = 1;
    for (var i = 0; i < 4 + bits; i++) {
      scale *= 2;
    }
    value += coded * scale;
    for (var i = 0; i < headerSize; i++) {
      out[at + i] = value % 256;
      value ~/= 256;
    }
  }
}

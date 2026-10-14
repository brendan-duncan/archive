import 'dart:typed_data';

import '../../util/archive_exception.dart';

import 'zstd_bit_reader.dart';
import 'zstd_constants.dart';
import 'zstd_fse.dart';

/// One packed row per code, `symbol | (nbBits << 8)`
class ZstdHuffmanTable {
  final Uint16List rows = Uint16List(1 << zstdHuffmanLogMax);
  int tableLog = 0;

  /// How many symbols the description covered, which an encoder needs to read
  /// the same weights back
  int symbolCount = 0;
}

class ZstdHuffmanException extends ArchiveException {
  ZstdHuffmanException(super.message);
  @override
  String toString() => 'ZstdHuffmanException: $message';
}

/// Scratch a decoder allocates once per frame and reuses for every table
class ZstdHuffmanScratch {
  final Uint8List weights = Uint8List(zstdHuffmanSymbolCount);
  final Int16List counts = Int16List(zstdHuffmanSymbolCount);
  final Uint8List spread = Uint8List(1 << zstdHuffmanWeightLogMax);
  final Uint16List nextState = Uint16List(zstdHuffmanSymbolCount);
  final Uint32List rankStart = Uint32List(zstdHuffmanLogMax + 2);
  final ZstdFseTable weightTable = ZstdFseTable(zstdHuffmanWeightLogMax);
  final ZstdBitReader reader = ZstdBitReader();
}

/// Reads a tree description into [table] and returns the bytes it occupied
int readHuffmanTable(Uint8List data, int start, int end, ZstdHuffmanTable table,
    ZstdHuffmanScratch scratch) {
  if (start >= end) {
    _treeDescriptionIsEmpty();
  }
  final header = data[start];
  final weights = scratch.weights;

  final int weightCount;
  final int bytesRead;
  if (header >= 128) {
    weightCount = header - 127;
    final byteLength = (weightCount + 1) >> 1;
    if (start + 1 + byteLength > end) {
      _directWeightsAreTruncated();
    }
    for (var i = 0; i < weightCount; i += 2) {
      final byte = data[start + 1 + (i >> 1)];
      weights[i] = byte >> 4;
      if (i + 1 < weightCount) {
        weights[i + 1] = byte & 0xf;
      }
    }
    bytesRead = 1 + byteLength;
  } else {
    if (start + 1 + header > end) {
      _compressedWeightsAreTruncated();
    }
    weightCount = _readFseWeights(data, start + 1, header, weights, scratch);
    bytesRead = 1 + header;
  }

  _buildFromWeights(table, weights, weightCount, scratch.rankStart);
  return bytesRead;
}

/// Two states share one table and take turns, the first taking even indices
int _readFseWeights(Uint8List data, int start, int length, Uint8List weights,
    ZstdHuffmanScratch scratch) {
  final distribution = readFseDistribution(
      data, start, start + length, scratch.counts, zstdHuffmanSymbolCount - 1,
      maxAccuracyLog: zstdHuffmanWeightLogMax);
  buildFseTable(
      scratch.weightTable,
      distribution.counts,
      distribution.maxSymbol,
      distribution.accuracyLog,
      scratch.spread,
      scratch.nextState);

  final reader = scratch.reader;
  if (!reader.setStream(
      data, start + distribution.bytesRead, length - distribution.bytesRead)) {
    _weightBitstreamIsEmpty();
  }

  final rows = scratch.weightTable.rows;
  final log = scratch.weightTable.accuracyLog;
  var state1 = reader.read(log);
  var state2 = reader.read(log);
  if (reader.isOverrun) {
    _weightBitstreamLacksIts();
  }

  // The stream ends mid symbol by design: whichever state was not just read is
  // decoded once more and the process stops
  var count = 0;
  while (true) {
    if (count + 2 >= zstdHuffmanSymbolCount) {
      _tooManyWeights();
    }
    var row = rows[state1];
    weights[count++] = row & 0xff;
    state1 = (row >>> 16) + reader.read((row >> 8) & 0xff);
    reader.reload();
    if (reader.isOverrun) {
      row = rows[state2];
      weights[count++] = row & 0xff;
      break;
    }
    if (count + 2 >= zstdHuffmanSymbolCount) {
      _tooManyWeights();
    }
    row = rows[state2];
    weights[count++] = row & 0xff;
    state2 = (row >>> 16) + reader.read((row >> 8) & 0xff);
    reader.reload();
    if (reader.isOverrun) {
      row = rows[state1];
      weights[count++] = row & 0xff;
      break;
    }
  }
  return count;
}

/// The final symbol's weight is not stored: it brings the total to the next
/// power of two
void _buildFromWeights(ZstdHuffmanTable table, Uint8List weights,
    int weightCount, Uint32List rankStart) {
  if (weightCount < 1 || weightCount >= zstdHuffmanSymbolCount) {
    _weightCountOutOfRange(weightCount);
  }

  var sum = 0;
  for (var i = 0; i < weightCount; i++) {
    final w = weights[i];
    if (w > zstdHuffmanLogMax) {
      _weightTooLarge(w);
    }
    if (w > 0) {
      sum += 1 << (w - 1);
    }
  }
  if (sum == 0) {
    _everyWeightIsZero();
  }

  final tableLog = zstdHighestBit(sum) + 1;
  if (tableLog > zstdHuffmanLogMax) {
    _tableLogTooLarge(tableLog);
  }
  final tableSize = 1 << tableLog;
  final left = tableSize - sum;
  if (left <= 0 || (left & (left - 1)) != 0) {
    _weightsDoNotComplete();
  }
  weights[weightCount] = zstdHighestBit(left) + 1;
  final symbolCount = weightCount + 1;
  table.symbolCount = symbolCount;

  // Codes go to the lightest weight first, and within a weight in symbol order,
  // so a cursor per weight is enough to place every run
  for (var w = rankStart.length - 1; w >= 0; w--) {
    rankStart[w] = 0;
  }
  for (var s = 0; s < symbolCount; s++) {
    final w = weights[s];
    if (w > 0) {
      rankStart[w] += 1 << (w - 1);
    }
  }
  // `HUF_readStats_body`: weight one is the longest code, so a complete tree
  // pairs them off and cannot hold fewer than two. The rank holds one slot per
  // such symbol, so it is the count
  final ones = rankStart[1];
  if (ones < 2 || ones & 1 != 0) {
    _weightOnesDoNotPair(ones);
  }
  var position = 0;
  for (var w = 1; w <= tableLog; w++) {
    final width = rankStart[w];
    rankStart[w] = position;
    position += width;
  }
  if (position != tableSize) {
    _weightsDoNotFill();
  }

  final rows = table.rows;
  table.tableLog = tableLog;
  for (var s = 0; s < symbolCount; s++) {
    final w = weights[s];
    if (w == 0) {
      continue;
    }
    final entry = s | ((tableLog + 1 - w) << 8);
    final width = 1 << (w - 1);
    var at = rankStart[w];
    for (var i = 0; i < width; i++) {
      rows[at + i] = entry;
    }
    rankStart[w] = at + width;
  }
}

/// A stream with no symbols is still read: `BIT_initDStream` and
/// `BIT_endOfDStream` run over it either way, so its bytes have to hold the
/// end marker and nothing above it
void checkEmptyHuffmanStream(Uint8List src, int start, int length) {
  final reader = ZstdBitReader();
  if (!reader.setStream(src, start, length) || !reader.isAtEnd) {
    _emptyStreamCarriesBits();
  }
}

/// One symbol at a time through the shared reader, for streams too short
/// for the eight byte container and for targets without one
void decodeHuffmanStreamSlow(ZstdHuffmanTable table, Uint8List src, int start,
    int length, Uint8List dst, int dstStart, int count) {
  if (count == 0) {
    checkEmptyHuffmanStream(src, start, length);
    return;
  }
  final reader = ZstdBitReader();
  if (!reader.setStream(src, start, length)) {
    _streamIsEmptyOr();
  }
  final rows = table.rows;
  final tableLog = table.tableLog;
  for (var i = 0; i < count; i++) {
    if (reader.isOverrun) {
      _streamIsShorterThan();
    }
    final row = rows[reader.peek(tableLog)];
    dst[dstStart + i] = row & 0xff;
    reader.skip(row >> 8);
    reader.reload();
  }
  if (!reader.isAtEnd) {
    _streamLengthMismatch();
  }
}

/// Every throw here is moved out of line: inline, the exception's own
/// construction puts an allocation and a call into a function that is
/// otherwise straight-line work, and costs registers where nothing throws
@pragma('vm:never-inline')
Never _treeDescriptionIsEmpty() =>
    throw ZstdHuffmanException('Tree description is empty');

@pragma('vm:never-inline')
Never _directWeightsAreTruncated() =>
    throw ZstdHuffmanException('Direct weights are truncated');

@pragma('vm:never-inline')
Never _compressedWeightsAreTruncated() =>
    throw ZstdHuffmanException('Compressed weights are truncated');

@pragma('vm:never-inline')
Never _weightBitstreamIsEmpty() =>
    throw ZstdHuffmanException('Weight bitstream is empty or unterminated');

@pragma('vm:never-inline')
Never _weightBitstreamLacksIts() =>
    throw ZstdHuffmanException('Weight bitstream lacks its two initial states');

@pragma('vm:never-inline')
Never _tooManyWeights() => throw ZstdHuffmanException('Too many weights');

@pragma('vm:never-inline')
Never _everyWeightIsZero() =>
    throw ZstdHuffmanException('Every weight is zero');

@pragma('vm:never-inline')
Never _weightsDoNotComplete() =>
    throw ZstdHuffmanException('Weights do not complete a Huffman tree');

@pragma('vm:never-inline')
Never _weightsDoNotFill() =>
    throw ZstdHuffmanException('Weights do not fill the table exactly');

@pragma('vm:never-inline')
Never _streamIsEmptyOr() =>
    throw ZstdHuffmanException('Stream is empty or unterminated');

@pragma('vm:never-inline')
Never _emptyStreamCarriesBits() =>
    throw ZstdHuffmanException('Stream owes no symbol but carries bits');

@pragma('vm:never-inline')
Never _streamIsShorterThan() =>
    throw ZstdHuffmanException('Stream is shorter than its literals');

@pragma('vm:never-inline')
Never _streamLengthMismatch() =>
    throw ZstdHuffmanException('Stream length does not match its literals');

@pragma('vm:never-inline')
Never _weightCountOutOfRange(int weightCount) =>
    throw ZstdHuffmanException('Weight count $weightCount is out of range');

@pragma('vm:never-inline')
Never _weightTooLarge(int w) =>
    throw ZstdHuffmanException('Weight $w exceeds the longest code allowed');

@pragma('vm:never-inline')
Never _weightOnesDoNotPair(int ones) => throw ZstdHuffmanException(
    'A complete tree needs an even count of two or more longest codes, not '
    '$ones');

@pragma('vm:never-inline')
Never _tableLogTooLarge(int tableLog) =>
    throw ZstdHuffmanException('Table log $tableLog is too large');

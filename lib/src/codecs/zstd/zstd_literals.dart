import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_huffman.dart';
import 'zstd_huffman_loop.dart';

class ZstdLiteralsException extends ArchiveException {
  ZstdLiteralsException(super.message);
  @override
  String toString() => 'ZstdLiteralsException: $message';
}

/// Decodes the literals of one block, and holds the Huffman table that a later
/// treeless section in the same frame reuses.
///
/// The literals land in the buffer passed in, past the room reserved for the
/// block's own output, so the sequence loop reads them and writes the output
/// through one and the same view
class ZstdLiterals {
  Uint8List _buffer = Uint8List(0);
  int _at = 0;
  int length = 0;

  final ZstdHuffmanTable _table = ZstdHuffmanTable();
  final ZstdHuffmanScratch _scratch = ZstdHuffmanScratch();
  final Uint32List _starts = Uint32List(4);
  final Uint32List _lengths = Uint32List(4);
  bool _hasTable = false;

  /// A tree is never kept across frames
  void reset() {
    _hasTable = false;
    length = 0;
  }

  /// Copies the dictionary's tree in, so a treeless first block has one. It is
  /// copied rather than referenced because a later block overwrites it
  void loadDictionary(ZstdDictionary dictionary) {
    _table.rows.setAll(0, dictionary.huffman.rows);
    _table.tableLog = dictionary.huffman.tableLog;
    _hasTable = true;
  }

  /// Decodes the section at [start] into `into[at...]` and returns the bytes
  /// it occupied
  int decode(Uint8List src, int start, int end, int blockSizeMax,
      Uint8List into, int at) {
    _buffer = into;
    _at = at;
    if (start >= end) {
      _literalsSectionIsEmpty();
    }
    final header = src[start];
    final type = header & 3;
    if (type == zstdLiteralsRaw || type == zstdLiteralsRle) {
      return _decodeStored(src, start, end, blockSizeMax, type, header);
    }
    return _decodeCoded(src, start, end, blockSizeMax, type, header);
  }

  int _decodeStored(Uint8List src, int start, int end, int blockSizeMax,
      int type, int header) {
    final sizeFormat = (header >> 2) & 3;
    final int size;
    final int headerSize;
    if (sizeFormat & 1 == 0) {
      size = header >> 3;
      headerSize = 1;
    } else if (sizeFormat == 1) {
      if (start + 2 > end) {
        _literalsHeaderIsTruncated();
      }
      size = (header >> 4) | (src[start + 1] << 4);
      headerSize = 2;
    } else {
      if (start + 3 > end) {
        _literalsHeaderIsTruncated();
      }
      size = (header >> 4) | (src[start + 1] << 4) | (src[start + 2] << 12);
      headerSize = 3;
    }
    if (size > blockSizeMax) {
      _literalsAreLargerThan();
    }

    final from = start + headerSize;
    if (type == zstdLiteralsRle) {
      if (from >= end) {
        _rleLiteralByteIs();
      }
      _buffer.fillRange(_at, _at + size, src[from]);
      length = size;
      return headerSize + 1;
    }
    if (from + size > end) {
      _rawLiteralsAreTruncated();
    }
    _buffer.setRange(_at, _at + size, src, from);
    length = size;
    return headerSize + size;
  }

  int _decodeCoded(Uint8List src, int start, int end, int blockSizeMax,
      int type, int header) {
    final sizeFormat = (header >> 2) & 3;
    final int bits;
    final int headerSize;
    if (sizeFormat <= 1) {
      bits = 10;
      headerSize = 3;
    } else if (sizeFormat == 2) {
      bits = 14;
      headerSize = 4;
    } else {
      bits = 18;
      headerSize = 5;
    }
    if (start + headerSize > end) {
      _literalsHeaderIsTruncated();
    }

    // The header reaches 40 bits, wider than a shift is portable, so it is
    // built and taken apart by arithmetic
    var packed = 0;
    for (var i = headerSize - 1; i >= 0; i--) {
      packed = packed * 256 + src[start + i];
    }
    final mask = (1 << bits) - 1;
    final regenerated = (packed ~/ 16) & mask;
    final compressed = (packed ~/ (1 << (4 + bits))) & mask;
    if (regenerated > blockSizeMax) {
      _literalsAreLargerThan();
    }
    if (compressed == 0 || start + headerSize + compressed > end) {
      _codedLiteralsAreTruncated();
    }

    var at = start + headerSize;
    final sectionEnd = at + compressed;
    if (type == zstdLiteralsCompressed) {
      at += readHuffmanTable(src, at, sectionEnd, _table, _scratch);
      _hasTable = true;
    } else if (!_hasTable) {
      _treelessLiteralsWithoutAn();
    }

    final streamsSize = sectionEnd - at;
    if (streamsSize <= 0) {
      _literalStreamsAreMissing();
    }
    if (sizeFormat == 0) {
      decodeHuffmanStream(
          _table, src, at, streamsSize, _buffer, _at, regenerated);
    } else {
      _decodeFour(src, at, streamsSize, regenerated);
    }
    length = regenerated;
    return headerSize + compressed;
  }

  /// The jump table gives the first three sizes, the fourth is the remainder
  void _decodeFour(Uint8List src, int at, int streamsSize, int regenerated) {
    if (streamsSize < 10) {
      _fourStreamsNeedAt();
    }
    // `HUF_decompress4X*_usingDTable_internal_body`: below six the split into
    // four segments has no shape, whatever the streams hold
    if (regenerated < 6) {
      _fourStreamsNeedSix();
    }
    final l0 = src[at] | (src[at + 1] << 8);
    final l1 = src[at + 2] | (src[at + 3] << 8);
    final l2 = src[at + 4] | (src[at + 5] << 8);
    if (l0 == 0 || l1 == 0 || l2 == 0) {
      _jumpTableDeclaresAn();
    }
    final used = 6 + l0 + l1 + l2;
    if (used >= streamsSize) {
      _jumpTableOverrunsThe();
    }

    _starts[0] = at + 6;
    _starts[1] = _starts[0] + l0;
    _starts[2] = _starts[1] + l1;
    _starts[3] = _starts[2] + l2;
    _lengths[0] = l0;
    _lengths[1] = l1;
    _lengths[2] = l2;
    _lengths[3] = streamsSize - used;

    decodeHuffman4Streams(_table, src, _starts, _lengths, _buffer, _at,
        regenerated, (regenerated + 3) >> 2);
  }
}

/// Every throw here is moved out of line: inline, the exception's own
/// construction puts an allocation and a call into a function that is
/// otherwise straight-line work, and costs registers where nothing throws
@pragma('vm:never-inline')
Never _literalsSectionIsEmpty() =>
    throw ZstdLiteralsException('Literals section is empty');

@pragma('vm:never-inline')
Never _literalsHeaderIsTruncated() =>
    throw ZstdLiteralsException('Literals header is truncated');

@pragma('vm:never-inline')
Never _literalsAreLargerThan() =>
    throw ZstdLiteralsException('Literals are larger than a block');

@pragma('vm:never-inline')
Never _rleLiteralByteIs() =>
    throw ZstdLiteralsException('RLE literal byte is missing');

@pragma('vm:never-inline')
Never _rawLiteralsAreTruncated() =>
    throw ZstdLiteralsException('Raw literals are truncated');

@pragma('vm:never-inline')
Never _codedLiteralsAreTruncated() =>
    throw ZstdLiteralsException('Coded literals are truncated');

@pragma('vm:never-inline')
Never _treelessLiteralsWithoutAn() =>
    throw ZstdLiteralsException('Treeless literals without an earlier tree');

@pragma('vm:never-inline')
Never _literalStreamsAreMissing() =>
    throw ZstdLiteralsException('Literal streams are missing');

@pragma('vm:never-inline')
Never _fourStreamsNeedAt() =>
    throw ZstdLiteralsException('Four streams need at least ten bytes');

@pragma('vm:never-inline')
Never _fourStreamsNeedSix() =>
    throw ZstdLiteralsException('Four streams need at least six literals');

@pragma('vm:never-inline')
Never _jumpTableDeclaresAn() =>
    throw ZstdLiteralsException('Jump table declares an empty stream');

@pragma('vm:never-inline')
Never _jumpTableOverrunsThe() =>
    throw ZstdLiteralsException('Jump table overruns the streams');

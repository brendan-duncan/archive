import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/input_stream.dart';
import '../../util/xxh64.dart';
import 'zstd_block_decoder.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_window.dart';

class ZstdFrameException extends ArchiveException {
  ZstdFrameException(super.message);
  @override
  String toString() => 'ZstdFrameException: $message';
}

class ZstdFrameHeader {
  /// Bytes the header occupied, not counting the magic number
  final int size;
  final int windowSize;
  final int? contentSize;
  final int dictionaryId;
  final bool hasChecksum;

  ZstdFrameHeader(this.size, this.windowSize, this.contentSize,
      this.dictionaryId, this.hasChecksum);

  int get blockSizeMax =>
      windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;

  /// Room one block needs above the position it starts at: its own output, the
  /// literals it reads, and the slack an overrunning copy writes into
  int get blockReserve => blockSizeMax * 2 + zstdCopySlack * 2;
}

/// A size above this cannot be held exactly where an int is a JavaScript
/// number, and is far past anything decodable either way
const _contentSizeMax = 35184372088832;

int _pow2(int exponent) {
  var value = 1;
  for (var i = 0; i < exponent; i++) {
    value *= 2;
  }
  return value;
}

/// Reads the header at [start], the byte after the magic number
ZstdFrameHeader readFrameHeader(
    Uint8List src, int start, int end, int maxWindowSize) {
  if (start >= end) {
    throw ZstdFrameException('Frame header is missing');
  }
  final descriptor = src[start];
  if (descriptor & 8 != 0) {
    throw ZstdFrameException('Reserved bit is set in the frame header');
  }
  var at = start + 1;
  final singleSegment = descriptor & 0x20 != 0;
  final hasChecksum = descriptor & 4 != 0;

  var windowSize = 0;
  if (!singleSegment) {
    if (at >= end) {
      throw ZstdFrameException('Window descriptor is missing');
    }
    final window = src[at];
    at += 1;
    // The exponent reaches 41, wider than a shift is portable
    final base = _pow2(10 + (window >> 3));
    windowSize = base + (base ~/ 8) * (window & 7);
  }

  final dictionaryIdSize = const [0, 1, 2, 4][descriptor & 3];
  if (at + dictionaryIdSize > end) {
    throw ZstdFrameException('Dictionary id is truncated');
  }
  var dictionaryId = 0;
  for (var i = 0; i < dictionaryIdSize; i++) {
    dictionaryId |= src[at + i] << (i << 3);
  }
  at += dictionaryIdSize;

  final contentSizeFlag = descriptor >> 6;
  final contentSizeSize =
      contentSizeFlag == 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
  if (at + contentSizeSize > end) {
    throw ZstdFrameException('Frame content size is truncated');
  }
  int? contentSize;
  if (contentSizeSize > 0) {
    var value = 0;
    for (var i = contentSizeSize - 1; i >= 0; i--) {
      if (value > _contentSizeMax) {
        throw ZstdFrameException('Frame content size is too large to decode');
      }
      value = value * 256 + src[at + i];
    }
    if (contentSizeSize == 2) {
      value += 256;
    }
    contentSize = value;
    at += contentSizeSize;
  }

  if (singleSegment) {
    windowSize = contentSize!;
  }
  // The declared window sets how much a decoder holds for the frame, so we
  // check it alone against the limit. A frame can declare any content size,
  // and using it here would let a false size allocate past the limit
  if (windowSize > maxWindowSize) {
    throw ArchiveLimitException(
        'Window of $windowSize bytes is above the $maxWindowSize limit');
  }

  return ZstdFrameHeader(
      at - start, windowSize, contentSize, dictionaryId, hasChecksum);
}

/// Runs the blocks of one frame. The block decoder it holds keeps the
/// entropy tables from block to block, so one instance serves one frame
class ZstdFrameDecoder {
  final ZstdBlockDecoder _blocks = ZstdBlockDecoder();
  final Uint32List _rep = Uint32List(3);
  final Xxh64 _hash = Xxh64();

  /// Decodes the blocks that follow [header], pulling one block at a time from
  /// [input] so nothing larger than a block is ever held
  void decodeBlocksFrom(
      InputStream input,
      ZstdWindow window,
      ZstdFrameHeader header,
      bool verify,
      ZstdDictionary? dictionary,
      Uint8List scratch) {
    _blocks.reset(dictionary);
    _rep.setAll(0, dictionary?.repeatOffsets ?? zstdInitialRepeatOffsets);
    final checked = header.hasChecksum && verify;
    if (checked) {
      _hash.reset();
    }

    final blockSizeMax = header.blockSizeMax;
    final reserve = header.blockReserve;
    window.blockReserve = reserve;
    final before = window.length;
    while (true) {
      _take(input, scratch, 0, 3, 'Block header is truncated');
      final head = scratch[0] | (scratch[1] << 8) | (scratch[2] << 16);
      // For an RLE block the size field is the regenerated size and the body
      // is one byte, so we compare blockSizeMax with that field
      final size = head >> 3;
      final payload = (head >> 1) & 3 == zstdBlockRle ? 1 : size;
      if (size > blockSizeMax) {
        throw ZstdFrameException('Block of $size bytes is above the '
            '$blockSizeMax its frame allows');
      }
      // A stream holding its own bytes returns a view of them, which saves
      // copying every block into a buffer only to read it once
      var body = input.viewBytes(payload);
      var at = 0;
      if (body == null) {
        _take(input, scratch, 3, payload, 'Block is truncated');
        body = scratch;
        at = 3;
      }
      window.reserve(reserve);
      final from = window.position;
      _blocks.decode(scratch, 0, 3, window, _rep, blockSizeMax,
          body: body, bodyAt: at);
      if (checked) {
        _hash.update(window.buffer, from, window.position - from);
      }
      _checkNotAbove(window, from, before, header);
      if (window.emitEachBlock) {
        window.emit();
      }
      if (_blocks.isLast) {
        break;
      }
    }

    _checkProduced(window.length - before, header);
    if (header.hasChecksum) {
      _take(input, scratch, 0, 4, 'Content checksum is truncated');
      _checkDigest(
          scratch[0] |
              (scratch[1] << 8) |
              (scratch[2] << 16) |
              (scratch[3] << 24),
          checked);
    }
  }

  /// A frame that declared its content size has to have written exactly that
  static void _checkProduced(int produced, ZstdFrameHeader header) {
    final expected = header.contentSize;
    if (expected != null && produced != expected) {
      throw ZstdFrameException(
          'Frame produced $produced bytes against the $expected it declared');
    }
  }

  static void _checkNotAbove(
      ZstdWindow window, int from, int before, ZstdFrameHeader header) {
    final expected = header.contentSize;
    final produced = window.length - before;
    if (expected != null && produced > expected) {
      window.position = from;
      _checkProduced(produced, header);
    }
  }

  /// The frame has the low half of an XXH64 of everything it decoded to
  void _checkDigest(int stored, bool checked) {
    if (checked && _hash.digestLow != stored) {
      throw ArchiveChecksumException('Content checksum does not match');
    }
  }

  static void _take(
      InputStream input, Uint8List into, int at, int count, String short) {
    if (count == 0) {
      return;
    }
    if (input.length < count) {
      throw ZstdFrameException(short);
    }
    if (input.readInto(into, at, count) < count) {
      throw ZstdFrameException(short);
    }
  }

  /// Decodes the blocks that follow [header] and returns the bytes they and
  /// the trailing checksum occupied
  int decodeBlocks(Uint8List src, int start, int end, ZstdWindow window,
      ZstdFrameHeader header, bool verify, ZstdDictionary? dictionary) {
    _blocks.reset(dictionary);
    _rep.setAll(0, dictionary?.repeatOffsets ?? zstdInitialRepeatOffsets);
    final checked = header.hasChecksum && verify;
    if (checked) {
      _hash.reset();
    }

    final blockSizeMax = header.blockSizeMax;
    final reserve = header.blockReserve;
    window.blockReserve = reserve;
    final before = window.length;
    var at = start;
    while (true) {
      // Reserving here rather than leaving it to the block keeps the range the
      // block wrote contiguous and known. The checksum needs it that way
      window.reserve(reserve);
      final from = window.position;
      at += _blocks.decode(src, at, end, window, _rep, blockSizeMax);
      if (checked) {
        _hash.update(window.buffer, from, window.position - from);
      }
      _checkNotAbove(window, from, before, header);
      if (window.emitEachBlock) {
        window.emit();
      }
      if (_blocks.isLast) {
        break;
      }
    }

    _checkProduced(window.length - before, header);
    if (header.hasChecksum) {
      if (at + 4 > end) {
        throw ZstdFrameException('Content checksum is truncated');
      }
      _checkDigest(
          src[at] |
              (src[at + 1] << 8) |
              (src[at + 2] << 16) |
              (src[at + 3] << 24),
          checked);
      at += 4;
    }
    return at - start;
  }
}

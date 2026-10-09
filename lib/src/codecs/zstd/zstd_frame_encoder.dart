import 'dart:math' as math;
import 'dart:typed_data';

import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'xxhash64.dart';
import 'zstd_block_encoder.dart';
import 'zstd_frame_decoder.dart';
import 'zstd_match_finder.dart';
import 'zstd_platform.dart';

enum _Strategy { fast, doubleFast, row, lazy }

// What a compression level does: the match finder, the window, the table
// sizes and how hard it searches.
class _LevelParams {
  final _Strategy strategy;
  final int windowLog;
  final int hashLog;
  // The long hash table for doubleFast, all the rows for row, the chain for
  // lazy
  final int chainLog;
  final int searchLog;
  // The shortest match to look for, which is also how many bytes are hashed
  final int mls;
  // For fast, how far to step when there is no match; for lazy, how many
  // positions ahead to look for a better match.
  final int depth;

  const _LevelParams(this.strategy, this.windowLog, this.hashLog, this.chainLog,
      this.searchLog, this.mls, this.depth);
}

const _levels = <_LevelParams>[
  _LevelParams(_Strategy.fast, 19, 16, 0, 0, 6, 1), // 1
  _LevelParams(_Strategy.doubleFast, 20, 16, 17, 0, 6, 0), // 2
  _LevelParams(_Strategy.doubleFast, 21, 17, 18, 0, 5, 0), // 3
  _LevelParams(_Strategy.doubleFast, 21, 18, 19, 0, 5, 0), // 4
  _LevelParams(_Strategy.row, 21, 18, 19, 4, 5, 0), // 5
  _LevelParams(_Strategy.row, 21, 19, 20, 4, 5, 1), // 6
  _LevelParams(_Strategy.row, 21, 19, 20, 5, 5, 1), // 7
  _LevelParams(_Strategy.row, 21, 19, 20, 5, 5, 2), // 8
  _LevelParams(_Strategy.row, 22, 20, 21, 5, 5, 2), // 9
  _LevelParams(_Strategy.row, 22, 21, 22, 5, 5, 2), // 10
  _LevelParams(_Strategy.row, 22, 21, 22, 6, 5, 2), // 11
  _LevelParams(_Strategy.row, 22, 22, 23, 6, 5, 2), // 12
  _LevelParams(_Strategy.row, 23, 22, 23, 6, 5, 2), // 13
  _LevelParams(_Strategy.row, 23, 22, 24, 6, 5, 2), // 14
  _LevelParams(_Strategy.lazy, 23, 22, 23, 7, 5, 2), // 15
  _LevelParams(_Strategy.lazy, 23, 22, 24, 7, 5, 2), // 16
  _LevelParams(_Strategy.lazy, 23, 22, 24, 8, 5, 2), // 17
  _LevelParams(_Strategy.lazy, 23, 23, 24, 8, 5, 2), // 18
  _LevelParams(_Strategy.lazy, 23, 23, 24, 9, 5, 2), // 19
  _LevelParams(_Strategy.lazy, 25, 23, 25, 9, 5, 2), // 20
  _LevelParams(_Strategy.lazy, 26, 24, 25, 9, 5, 2), // 21
  _LevelParams(_Strategy.lazy, 27, 24, 25, 10, 4, 2), // 22
];

/// The lowest compression level, the fastest.
const int zstdMinLevel = -7;

/// The highest compression level.
const int zstdMaxLevel = 22;

/// Encodes one zstd frame.
class ZstdFrameEncoder {
  final int level;
  final bool checksum;

  ZstdFrameEncoder(this.level, this.checksum);

  /// Compresses everything left in [input] into one frame on [output].
  void encode(InputStream input, OutputStream output) {
    final total = input.length;
    var p = level <= 0 ? _levels[0] : _levels[level - 1];

    // No point in a window, or tables, much larger than the input.
    var windowLog = p.windowLog;
    final inputLog = math.max(10, (total - 1).bitLength);
    if (inputLog < windowLog) {
      windowLog = inputLog;
    }
    final hashLog = math.min(p.hashLog, windowLog + 1);
    final chainLog = math.min(p.chainLog, windowLog + 1);
    final windowSize = 1 << windowLog;

    final ZstdMatchFinder finder;
    switch (p.strategy) {
      case _Strategy.fast:
        finder = ZstdFastMatchFinder(
            hashLog, p.mls, level < 0 ? 1 - level : p.depth);
      case _Strategy.doubleFast:
        finder = ZstdDoubleFastMatchFinder(hashLog, chainLog, p.mls);
      case _Strategy.row:
        finder = ZstdRowMatchFinder(chainLog, p.searchLog.clamp(4, 6),
            p.searchLog, p.mls, p.depth, 8 << p.searchLog);
      case _Strategy.lazy:
        finder = ZstdLazyMatchFinder(
            hashLog, chainLog, p.searchLog, p.mls, p.depth, 8 << p.searchLog);
    }

    // The whole input fits in the window, so the frame header can say so and
    // leave the window size out.
    final singleSegment = total <= windowSize;
    _writeHeader(output, total, windowLog, singleSegment);

    final blockSize = math.min(zstdBlockSizeMax, windowSize);
    final hash = checksum ? XxHash64() : null;
    final seqs = ZstdSequenceStore();
    final blocks = ZstdBlockEncoder();

    void writeBlock(Uint8List src, ByteData d, int start, int end, bool last) {
      final length = end - start;
      hash?.update(src, start, end);
      if (_isRle(src, start, end)) {
        _writeBlockHeader(output, last, 1, length);
        output.writeByte(src[start]);
        return;
      }
      seqs.reset();
      finder.findMatches(src, d, start, end, windowSize, seqs);
      final size = blocks.compress(seqs, length);
      if (size < 0) {
        _writeBlockHeader(output, last, 0, length);
        output.writeBytes(Uint8List.sublistView(src, start, end));
      } else {
        blocks.commit();
        _writeBlockHeader(output, last, 2, size);
        output.writeBytes(Uint8List.sublistView(blocks.out, 0, size));
      }
    }

    if (total == 0) {
      _writeBlockHeader(output, true, 0, 0);
    } else if (input is InputMemoryStream) {
      // All of it at hand already, so nothing has to slide.
      var src = input.toUint8List();
      if (zstdIsWasm) {
        // The bytes may well live in a JavaScript array, every access to
        // which is a call out of wasm; one copy is far cheaper.
        src = Uint8List(total)..setRange(0, total, src);
      }
      final d = ByteData.sublistView(src);
      for (var pos = 0; pos < total; pos += blockSize) {
        final end = math.min(pos + blockSize, total);
        writeBlock(src, d, pos, end, end == total);
      }
      input.skip(total);
    } else {
      // Read in a window's worth and then some, slide it along as the
      // blocks are compressed. A slide keeps the window behind the next
      // block and moves the positions in the match finder's tables, by a
      // multiple of what they are indexed by.
      final alignment = finder.slideAlignment;
      final int capacity =
          windowSize + blockSize + math.max<int>(alignment, 1 << 20);
      final buf = Uint8List(math.min(capacity, total));
      final d = ByteData.sublistView(buf);
      var filled = 0;
      var pos = 0;
      var remaining = total;
      while (pos < filled || remaining > 0) {
        if (filled == buf.length && pos > windowSize) {
          final shift = (pos - windowSize) ~/ alignment * alignment;
          if (shift > 0) {
            buf.setRange(0, filled - shift, buf, shift);
            filled -= shift;
            pos -= shift;
            finder.slide(shift);
          }
        }
        if (remaining > 0 && filled < buf.length) {
          final n = math.min(buf.length - filled, remaining);
          buf.setRange(filled, filled + n, input.readBytes(n).toUint8List());
          filled += n;
          remaining -= n;
        }
        while (pos < filled && (filled - pos >= blockSize || remaining == 0)) {
          final end = math.min(pos + blockSize, filled);
          writeBlock(buf, d, pos, end, remaining == 0 && end == filled);
          pos = end;
        }
      }
    }

    if (hash != null) {
      final h = hash.digestLow32();
      output.writeByte(h & 0xff);
      output.writeByte((h >> 8) & 0xff);
      output.writeByte((h >> 16) & 0xff);
      output.writeByte(h >>> 24);
    }
  }

  static bool _isRle(Uint8List src, int start, int end) {
    final b = src[start];
    for (var i = start + 1; i < end; i++) {
      if (src[i] != b) {
        return false;
      }
    }
    return end - start > 1;
  }

  void _writeHeader(
      OutputStream output, int total, int windowLog, bool singleSegment) {
    // The magic number, little endian
    output
      ..writeByte(0x28)
      ..writeByte(0xB5)
      ..writeByte(0x2F)
      ..writeByte(0xFD);

    // The content size, in as few bytes as hold it. One byte is only
    // possible in a single segment frame, where no size field means one.
    int fcsCode;
    int fcsBytes;
    var fcsValue = total;
    if (singleSegment && total < 256) {
      fcsCode = 0;
      fcsBytes = 1;
    } else if (total < 65536 + 256 && total >= 256) {
      fcsCode = 1;
      fcsBytes = 2;
      fcsValue -= 256;
    } else if (total < 0x100000000) {
      fcsCode = 2;
      fcsBytes = 4;
    } else {
      fcsCode = 3;
      fcsBytes = 8;
    }

    output.writeByte(
        (fcsCode << 6) | (singleSegment ? 0x20 : 0) | (checksum ? 0x04 : 0));
    if (!singleSegment) {
      output.writeByte((windowLog - 10) << 3);
    }
    for (var i = 0; i < fcsBytes; i++) {
      output.writeByte(fcsValue % 256);
      fcsValue ~/= 256;
    }
  }

  static void _writeBlockHeader(
      OutputStream output, bool last, int type, int size) {
    final header = (last ? 1 : 0) | (type << 1) | (size << 3);
    output
      ..writeByte(header & 0xff)
      ..writeByte((header >> 8) & 0xff)
      ..writeByte(header >> 16);
  }
}

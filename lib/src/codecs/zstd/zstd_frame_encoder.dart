import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '../../util/xxh64.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_level_params.dart';

/// Writes one frame covering `src[start...end]`, header, blocks and checksum
class ZstdFrameEncoder {
  final Xxh64 _hash = Xxh64();
  final Uint32List _rep = Uint32List(3);

  final ZstdBlockSplitter _splitter = ZstdBlockSplitter();

  void encode(Uint8List src, int start, int end, OutputStream out,
      {bool checksum = true,
      int level = zstdDefaultLevel,
      ZstdDictionary? dictionary}) {
    _write(null, src, start, end - start, out,
        checksum: checksum, level: level, dictionary: dictionary);
  }

  /// Writes one frame of [size] bytes pulled from [input]. Only the window and
  /// the block being parsed are held, so the frame's memory follows the level
  /// rather than the input. The blocks fall where a whole buffer would put
  /// them, so the bytes are the ones [encode] would have written
  void encodeStream(InputStream input, int size, OutputStream out,
      {bool checksum = true,
      int level = zstdDefaultLevel,
      ZstdDictionary? dictionary}) {
    // A stream over memory returns its own buffer, which spares the frame
    // both the copy and the window
    final held = input.viewBytes(size);
    if (held != null) {
      _write(null, held, 0, size, out,
          checksum: checksum, level: level, dictionary: dictionary);
      return;
    }
    _write(input, null, 0, size, out,
        checksum: checksum, level: level, dictionary: dictionary);
  }

  void _write(
      InputStream? input, Uint8List? src, int start, int size, OutputStream out,
      {required bool checksum,
      required int level,
      required ZstdDictionary? dictionary}) {
    final dict =
        dictionary != null && dictionary.usableForEncode ? dictionary : null;
    final prefix = dict?.content.length ?? 0;
    // `ZSTD_getCParamRowSize` and `ZSTD_adjustCParams_internal` both size the
    // frame by the dictionary buffer, headers and all, not by its content
    final params =
        zstdParamsForLevel(level, size + (dictionary?.sourceSize ?? 0));
    // A frame that fits its level's window declares the content instead, which
    // costs a decoder nothing extra and saves the window field
    final singleSegment = size <= (1 << params.windowLog);
    final windowSize = singleSegment ? size : 1 << params.windowLog;
    // How far a match may reach is the level's window, which a frame declaring
    // its content does not shrink: with a dictionary the two differ
    final matchWindow = 1 << params.windowLog;

    final origin = out.length;
    _writeHeader(
        out, size, singleSegment, checksum, params.windowLog, dict?.id ?? 0);

    if (checksum) {
      _hash.reset();
      if (src != null) {
        _hash.update(src, start, size);
      }
    }

    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    final blocks = ZstdBlockEncoder(blockSizeMax, params);
    // A slide has to leave the low bits of a position alone for the chain and
    // the tree to stay addressable, so it goes in whole steps of this
    final step = blocks.slideStep;

    // The parse works in one buffer of absolute positions, so the dictionary
    // has to sit directly before the content it is a dictionary for. A frame
    // read from a stream keeps the window and enough spare beside it that a
    // slide, which visits every table, is amortized over the bytes it frees
    var slack = blocks.slideCost;
    if (slack < matchWindow) {
      slack = matchWindow;
    }
    var body = src;
    var at = start;
    if (src == null || dict != null) {
      var span = size;
      if (src == null && matchWindow + slack + blockSizeMax + step < span) {
        span = matchWindow + slack + blockSizeMax + step;
      }
      final held = Uint8List(prefix + span);
      if (dict != null) {
        held.setRange(0, prefix, dict.content);
      }
      if (src != null) {
        held.setRange(prefix, prefix + size, src, start);
      }
      body = held;
      at = prefix;
    }
    final buffer = body!;
    var base = at - prefix;

    _rep.setAll(0, dict?.repeatOffsets ?? zstdInitialRepeatOffsets);
    if (dict != null) {
      blocks.prime(buffer, base, at, dict);
    }

    if (size == 0) {
      blocks.encode(buffer, at, at, base, out, true, _rep);
    }
    // Everything a block saved so far. It stops the splitter from cutting up
    // data that does not compress
    var savings = 0;
    var filled = src == null ? at : at + size;
    var read = src == null ? 0 : size;
    var coded = 0;
    while (coded < size) {
      // A whole block has to be here before it can be parsed, and the front of
      // the buffer goes once the window has moved past it
      if (filled - at < blockSizeMax && read < size) {
        if (filled == buffer.length) {
          var delta = at > matchWindow ? at - matchWindow : 0;
          delta -= delta % step;
          buffer.setRange(0, filled - delta, buffer, delta);
          at -= delta;
          filled -= delta;
          base = base > delta ? base - delta : 0;
          blocks.slide(delta);
        }
        var want = buffer.length - filled;
        if (want > size - read) {
          want = size - read;
        }
        var got = 0;
        while (got < want) {
          final part = input!.readInto(buffer, filled + got, want - got);
          if (part <= 0) {
            throw ArchiveException('zstd: the input ended $want bytes early');
          }
          got += part;
        }
        if (checksum) {
          _hash.update(buffer, filled, want);
        }
        filled += want;
        read += want;
      }
      final left = size - coded;
      final take =
          _splitter.sizeFor(buffer, at, left, blockSizeMax, params, savings);
      // `ZSTD_checkDictValidity` measures from the end of the block, and what
      // it drops stays dropped
      if (blocks.dictionaryEnd != 0 &&
          at + take - blocks.dictionaryEnd > matchWindow) {
        blocks.dropDictionary();
      }
      final reach = blocks.dictionaryEnd != 0 ? base : at - matchWindow;
      final before = out.length;
      blocks.encode(buffer, at, at + take, reach > base ? reach : base, out,
          coded + take == size, _rep);
      savings += take - (out.length - before);
      at += take;
      coded += take;
      // The first block's cost predicts the rest, near enough that a sink
      // holding its data takes the room once instead of doubling into it.
      // A frame never exceeds its own bound, so neither does the estimate
      if (coded == take && coded < size) {
        final bound = size + (size >> 7) + 64;
        final cost = out.length - origin;
        var want = cost + (cost * (size - coded)) ~/ coded;
        want += want >> 3;
        out.reserve(origin + (want < bound ? want : bound));
      }
    }

    if (checksum) {
      final digest = _hash.digestLow;
      out.writeByte(digest & 0xff);
      out.writeByte((digest >>> 8) & 0xff);
      out.writeByte((digest >>> 16) & 0xff);
      out.writeByte((digest >>> 24) & 0xff);
    }
  }

  static void _writeHeader(OutputStream out, int size, bool singleSegment,
      bool checksum, int windowLog, int dictionaryId) {
    final int contentSizeFlag;
    if (singleSegment && size < 256) {
      contentSizeFlag = 0;
    } else if (size >= 256 && size < 65536 + 256) {
      contentSizeFlag = 1;
    } else if (size < 4294967295) {
      contentSizeFlag = 2;
    } else {
      contentSizeFlag = 3;
    }
    // `ZSTD_writeFrameHeader`: as many bytes as the id needs, and the flag
    // names which of the four widths that is
    final idFlag = dictionaryId == 0
        ? 0
        : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));

    out.writeByte(zstdMagic & 0xff);
    out.writeByte((zstdMagic >>> 8) & 0xff);
    out.writeByte((zstdMagic >>> 16) & 0xff);
    out.writeByte((zstdMagic >>> 24) & 0xff);

    out.writeByte((contentSizeFlag << 6) |
        (singleSegment ? 0x20 : 0) |
        (checksum ? 4 : 0) |
        idFlag);

    if (!singleSegment) {
      // Exponent in the top five bits, eighths of it in the bottom three
      out.writeByte((windowLog - 10) << 3);
    }

    final idBytes = const [0, 1, 2, 4][idFlag];
    for (var i = 0; i < idBytes; i++) {
      out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
    }

    // Divided rather than shifted, since the size reaches past 32 bits and a
    // shift there is not portable
    var value = contentSizeFlag == 1 ? size - 256 : size;
    final bytes = contentSizeFlag == 0 ? 1 : 1 << contentSizeFlag;
    for (var i = 0; i < bytes; i++) {
      out.writeByte(value % 256);
      value ~/= 256;
    }
  }
}

void writeZstdFrameHeader(OutputStream out, int size, bool checksum,
        int windowLog, int dictionaryId) =>
    ZstdFrameEncoder._writeHeader(
        out, size, size <= (1 << windowLog), checksum, windowLog, dictionaryId);

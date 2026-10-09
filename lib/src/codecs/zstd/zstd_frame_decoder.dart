import 'dart:math' as math;
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'xxhash64.dart';
import 'zstd_bit_reader.dart';
import 'zstd_dictionary.dart';
import 'zstd_error.dart';
import 'zstd_fse.dart';
import 'zstd_huffman.dart';

// The zstd frame format, as described in RFC 8878 section 3.

/// The magic number that starts a zstd frame.
const int zstdFrameMagic = 0xFD2FB528;

/// Skippable frames have magic numbers from this to this plus 15.
const int zstdSkippableMagic = 0x184D2A50;

/// The largest a block can decompress to.
const int zstdBlockSizeMax = 128 * 1024;

// Spare bytes at the end of every buffer that literals and matches are copied
// from or to. Copies go a word at a time and may run up to a word past their
// end, which saves handling the last few bytes separately.
const int _slack = 32;

// Copies shorter than this go a word at a time, longer ones through setRange.
const int _longCopy = 128;

/// Decodes zstd frames, keeping the buffers it allocates for the next frame.
class ZstdFrameDecoder {
  final int maxWindowSize;
  final ZstdDictionary? dictionary;
  final bool verify;

  // The window: the dictionary content, if any, then the frame's output.
  // Matches refer back into it, so the window size most recent bytes are kept
  // when it fills up. Its last [_slack] bytes are not part of it.
  Uint8List _win = Uint8List(_slack);
  ByteData _winData = ByteData(_slack);
  int _pos = 0;
  // How large the window may grow for the current frame.
  int _capMax = 0;
  // How much history has to be kept when the window slides.
  int _keep = 0;
  int _blockMax = 0;

  // The current compressed block.
  final Uint8List _block = Uint8List(zstdBlockSizeMax + _slack);
  late final ByteData _blockData = ByteData.sublistView(_block);

  // The literals of the current block, which are either decoded into _lit or
  // left where they are in _block.
  final Uint8List _lit = Uint8List(zstdBlockSizeMax + _slack);
  late final ByteData _litData = ByteData.sublistView(_lit);
  Uint8List _litBuf = Uint8List(0);
  ByteData _litBufData = ByteData(0);
  int _litPos = 0;
  int _litEnd = 0;

  // The tables in force, which carry over from block to block: either one of
  // the buffers below, the predefined ones or the dictionary's.
  ZstdHuffmanTable? _huf;
  ZstdFseTable? _ll;
  ZstdFseTable? _of;
  ZstdFseTable? _ml;
  final ZstdHuffmanTable _ownHuf = ZstdHuffmanTable();
  final ZstdFseTable _llFse =
      ZstdFseTable(ZstdFseKind.literalsLength, zstdLlMaxLog);
  final ZstdFseTable _ofFse = ZstdFseTable(ZstdFseKind.offset, zstdOfMaxLog);
  final ZstdFseTable _mlFse =
      ZstdFseTable(ZstdFseKind.matchLength, zstdMlMaxLog);
  final ZstdFseTable _llRle = ZstdFseTable(ZstdFseKind.literalsLength, 0);
  final ZstdFseTable _ofRle = ZstdFseTable(ZstdFseKind.offset, 0);
  final ZstdFseTable _mlRle = ZstdFseTable(ZstdFseKind.matchLength, 0);

  int _rep1 = 1;
  int _rep2 = 4;
  int _rep3 = 8;

  final ZstdBitReader _br = ZstdBitReader();
  XxHash64? _hash;

  ZstdFrameDecoder(
      {required this.maxWindowSize, this.dictionary, required this.verify});

  int get _winLength => _win.length - _slack;

  static int _byte(InputStream input) {
    if (input.isEOS) {
      throw ZstdFormatError('Truncated frame');
    }
    return input.readByte();
  }

  /// Reads a little endian number of [n] bytes, at most 8. Above 2^53 the
  /// result is approximate where ints are JavaScript numbers, which only
  /// matters for sizes far too large to decode anyway.
  static int readLittleEndian(InputStream input, int n) {
    var v = 0;
    var scale = 1;
    for (var i = 0; i < n; i++) {
      v += _byte(input) * scale;
      scale *= 256;
    }
    return v;
  }

  /// Decodes one frame, whose magic number has already been read, from
  /// [input] to [output].
  void decodeFrame(InputStream input, OutputStream output) {
    final descriptor = _byte(input);
    final fcsFlag = descriptor >> 6;
    final singleSegment = descriptor & 0x20 != 0;
    final hasChecksum = descriptor & 0x04 != 0;
    final didFlag = descriptor & 0x03;
    if (descriptor & 0x08 != 0) {
      throw ZstdFormatError('Reserved frame header bit set');
    }

    var windowSize = 0;
    if (!singleSegment) {
      final wd = _byte(input);
      final log = 10 + (wd >> 3);
      if (log > 31) {
        throw ZstdFormatError('Window size 2^$log exceeds maxWindowSize');
      }
      final base = 1 << log;
      windowSize = base + (base ~/ 8) * (wd & 7);
    }

    final dictId = readLittleEndian(input, const [0, 1, 2, 4][didFlag]);
    final fcsSize = const [0, 2, 4, 8][fcsFlag];
    var contentSize = -1;
    if (fcsSize != 0 || singleSegment) {
      contentSize = readLittleEndian(input, fcsSize == 0 ? 1 : fcsSize);
      if (fcsSize == 2) {
        contentSize += 256;
      }
    }
    if (singleSegment) {
      windowSize = contentSize;
    }
    if (windowSize > maxWindowSize) {
      throw ZstdFormatError(
          'Window size $windowSize exceeds maxWindowSize $maxWindowSize');
    }

    final dict = dictionary;
    if (dictId != 0 && (dict == null || dict.id != dictId)) {
      throw ZstdFormatError('Frame requires dictionary $dictId');
    }

    _startFrame(windowSize, contentSize, dict);

    final hash = verify && hasChecksum ? (_hash ??= XxHash64()) : null;
    hash?.reset();
    var total = 0;

    for (;;) {
      if (input.length < 3) {
        throw ZstdFormatError('Truncated block header');
      }
      final header =
          input.readByte() | (input.readByte() << 8) | (input.readByte() << 16);
      final last = header & 1 != 0;
      final type = (header >> 1) & 3;
      final size = header >> 3;

      _ensureSpace();
      final start = _pos;
      final limit = math.min(start + _blockMax, _winLength);

      switch (type) {
        case 0:
          if (start + size > limit) {
            throw ZstdFormatError('Raw block too large');
          }
          _win.setRange(start, start + size, _readBlock(input, size));
          _pos = start + size;
        case 1:
          if (start + size > limit) {
            throw ZstdFormatError('RLE block too large');
          }
          _win.fillRange(start, start + size, _byte(input));
          _pos = start + size;
        case 2:
          if (size > _blockMax) {
            throw ZstdFormatError('Compressed block too large');
          }
          _block.setRange(0, size, _readBlock(input, size));
          final pos = _decodeLiterals(_block, 0, size);
          _decodeSequences(_block, pos, size, limit);
        default:
          throw ZstdFormatError('Reserved block type');
      }

      if (_pos > start) {
        output.writeBytes(Uint8List.sublistView(_win, start, _pos));
        hash?.update(_win, start, _pos);
        total += _pos - start;
      }
      if (last) {
        break;
      }
    }

    if (contentSize >= 0 && total != contentSize) {
      throw ZstdFormatError(
          'Frame decoded to $total bytes, its header says $contentSize');
    }
    if (hasChecksum) {
      if (input.length < 4) {
        throw ZstdFormatError('Truncated checksum');
      }
      final stored = readLittleEndian(input, 4);
      if (hash != null && hash.digestLow32() != stored) {
        throw ZstdFormatError('Checksum mismatch');
      }
    }
  }

  static Uint8List _readBlock(InputStream input, int size) {
    if (input.length < size) {
      throw ZstdFormatError('Truncated block');
    }
    return input.readBytes(size).toUint8List();
  }

  void _startFrame(int windowSize, int contentSize, ZstdDictionary? dict) {
    final content = dict?.content;
    final dictLength = content?.length ?? 0;

    _blockMax = math.min(windowSize, zstdBlockSizeMax);
    _keep = windowSize + dictLength;
    // Room to decode more than a window's worth before sliding, so that the
    // slide, which copies the whole window, does not happen too often.
    final extra =
        math.max(2 * zstdBlockSizeMax, math.min(windowSize, 64 * 1024 * 1024));
    _capMax = dictLength + windowSize + extra;
    var initial = math.min(_capMax, dictLength + 4 * zstdBlockSizeMax);
    if (contentSize >= 0 && dictLength + contentSize < _capMax) {
      // Everything fits, so the window never has to slide, or grow.
      _capMax = dictLength + contentSize;
      initial = _capMax;
    }
    if (_winLength < initial) {
      _win = Uint8List(initial + _slack);
      _winData = ByteData.sublistView(_win);
    }
    if (content != null) {
      _win.setRange(0, dictLength, content);
    }
    _pos = dictLength;

    _huf = dict?.huffman;
    _ll = dict?.llTable;
    _of = dict?.ofTable;
    _ml = dict?.mlTable;
    final reps = dict?.repeatOffsets ?? const [1, 4, 8];
    _rep1 = reps[0];
    _rep2 = reps[1];
    _rep3 = reps[2];
  }

  // Makes room for a block, growing the window or sliding it.
  void _ensureSpace() {
    if (_winLength - _pos >= _blockMax) {
      return;
    }
    if (_winLength < _capMax) {
      final size =
          math.min(_capMax, math.max(_winLength * 2, _pos + _blockMax));
      _win = Uint8List(size + _slack)..setRange(0, _pos, _win);
      _winData = ByteData.sublistView(_win);
      if (_winLength - _pos >= _blockMax) {
        return;
      }
    }
    final keep = math.min(_pos, _keep);
    if (keep < _pos) {
      _win.setRange(0, keep, _win, _pos - keep);
      _pos = keep;
    }
  }

  // Decodes the literals section, returning where the sequences section
  // starts.
  int _decodeLiterals(Uint8List src, int pos, int end) {
    if (pos >= end) {
      throw ZstdFormatError('Missing literals section');
    }
    final b0 = src[pos];
    final type = b0 & 3;
    final sizeFormat = (b0 >> 2) & 3;

    if (type < 2) {
      // Raw or RLE
      final headerSize = switch (sizeFormat) { 1 => 2, 3 => 3, _ => 1 };
      if (pos + headerSize > end) {
        throw ZstdFormatError('Truncated literals header');
      }
      final regenerated = switch (headerSize) {
        1 => b0 >> 3,
        2 => (b0 >> 4) | (src[pos + 1] << 4),
        _ => (b0 >> 4) | (src[pos + 1] << 4) | (src[pos + 2] << 12),
      };
      pos += headerSize;
      if (regenerated > zstdBlockSizeMax) {
        throw ZstdFormatError('Literals too large');
      }
      if (type == 0) {
        if (pos + regenerated > end) {
          throw ZstdFormatError('Truncated raw literals');
        }
        // Left in the block, which has the slack the copies need.
        _litBuf = _block;
        _litBufData = _blockData;
        _litPos = pos;
        _litEnd = pos + regenerated;
        return pos + regenerated;
      }
      if (pos >= end) {
        throw ZstdFormatError('Truncated RLE literals');
      }
      _lit.fillRange(0, regenerated, src[pos]);
      _setDecodedLiterals(regenerated);
      return pos + 1;
    }

    // Huffman coded, with a new table or the previous one
    final headerSize = sizeFormat < 2 ? 3 : sizeFormat + 2;
    if (pos + headerSize > end) {
      throw ZstdFormatError('Truncated literals header');
    }
    final b1 = src[pos + 1];
    final b2 = src[pos + 2];
    int regenerated;
    int compressed;
    switch (headerSize) {
      case 3:
        regenerated = (b0 >> 4) | ((b1 & 0x3f) << 4);
        compressed = (b1 >> 6) | (b2 << 2);
      case 4:
        final b3 = src[pos + 3];
        regenerated = (b0 >> 4) | (b1 << 4) | ((b2 & 0x03) << 12);
        compressed = (b2 >> 2) | (b3 << 6);
      default:
        final b3 = src[pos + 3];
        final b4 = src[pos + 4];
        regenerated = (b0 >> 4) | (b1 << 4) | ((b2 & 0x3f) << 12);
        compressed = (b2 >> 6) | (b3 << 2) | (b4 << 10);
    }
    pos += headerSize;
    if (regenerated > zstdBlockSizeMax) {
      throw ZstdFormatError('Literals too large');
    }
    final dataEnd = pos + compressed;
    if (dataEnd > end) {
      throw ZstdFormatError('Truncated compressed literals');
    }

    var p = pos;
    if (type == 2) {
      p = _ownHuf.readDescription(src, p, dataEnd);
      _huf = _ownHuf;
    }
    final huf = _huf;
    if (huf == null) {
      throw ZstdFormatError('Treeless literals with no previous table');
    }

    final out = _lit;
    final br = _br;
    if (sizeFormat == 0) {
      huf.decodeStream(src, p, dataEnd, out, 0, regenerated, br);
    } else {
      if (p + 6 > dataEnd) {
        throw ZstdFormatError('Truncated literals jump table');
      }
      final end1 = p + 6 + (src[p] | (src[p + 1] << 8));
      final end2 = end1 + (src[p + 2] | (src[p + 3] << 8));
      final end3 = end2 + (src[p + 4] | (src[p + 5] << 8));
      if (end3 > dataEnd) {
        throw ZstdFormatError('Corrupt literals jump table');
      }
      final segment = (regenerated + 3) >> 2;
      final lastSegment = regenerated - 3 * segment;
      if (lastSegment < 0) {
        throw ZstdFormatError('Too few literals for four streams');
      }
      huf.decodeStream(src, p + 6, end1, out, 0, segment, br);
      huf.decodeStream(src, end1, end2, out, segment, segment, br);
      huf.decodeStream(src, end2, end3, out, 2 * segment, segment, br);
      huf.decodeStream(src, end3, dataEnd, out, 3 * segment, lastSegment, br);
    }
    _setDecodedLiterals(regenerated);
    return dataEnd;
  }

  void _setDecodedLiterals(int count) {
    _litBuf = _lit;
    _litBufData = _litData;
    _litPos = 0;
    _litEnd = count;
  }

  // Picks the table for one of the sequence fields according to its mode,
  // reading whatever the mode needs, and returns where the next field's
  // description starts.
  (ZstdFseTable, int) _selectTable(
      int mode,
      Uint8List src,
      int pos,
      int end,
      ZstdFseTable? previous,
      ZstdFseTable predefined,
      ZstdFseTable fse,
      ZstdFseTable rle) {
    switch (mode) {
      case 0:
        return (predefined, pos);
      case 1:
        if (pos >= end) {
          throw ZstdFormatError('Truncated sequences header');
        }
        rle.buildRle(src[pos]);
        return (rle, pos + 1);
      case 2:
        return (fse, fse.readDescription(src, pos, end));
      default:
        if (previous == null) {
          throw ZstdFormatError('Repeated table with no previous table');
        }
        return (previous, pos);
    }
  }

  // Copies [length] bytes from [from] in [src] to [to] in [dst], a word at a
  // time, writing and reading up to a word past the end. The ranges must not
  // overlap within a word.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  @pragma('dart2js:prefer-inline')
  static void _wildCopy(
      ByteData dst, int to, ByteData src, int from, int length) {
    final end = to + length;
    if (ZstdBitReader.has64BitInts) {
      do {
        dst.setUint64(to, src.getUint64(from, Endian.little), Endian.little);
        to += 8;
        from += 8;
      } while (to < end);
    } else {
      do {
        dst.setUint32(to, src.getUint32(from, Endian.little), Endian.little);
        to += 4;
        from += 4;
      } while (to < end);
    }
  }

  void _decodeSequences(Uint8List src, int pos, int end, int limit) {
    if (pos >= end) {
      throw ZstdFormatError('Missing sequences section');
    }
    var nbSeq = src[pos++];
    if (nbSeq >= 128) {
      if (nbSeq == 255) {
        if (pos + 2 > end) {
          throw ZstdFormatError('Truncated sequences header');
        }
        nbSeq = src[pos] + (src[pos + 1] << 8) + 0x7F00;
        pos += 2;
      } else {
        if (pos >= end) {
          throw ZstdFormatError('Truncated sequences header');
        }
        nbSeq = ((nbSeq - 128) << 8) + src[pos++];
      }
    }

    final lit = _litBuf;
    final litData = _litBufData;
    var lp = _litPos;
    final le = _litEnd;
    final win = _win;
    final winData = _winData;
    var op = _pos;

    if (nbSeq > 0) {
      if (pos >= end) {
        throw ZstdFormatError('Truncated sequences header');
      }
      final modes = src[pos++];
      if (modes & 3 != 0) {
        throw ZstdFormatError('Reserved sequences header bits set');
      }
      final ZstdFseTable llT;
      final ZstdFseTable ofT;
      final ZstdFseTable mlT;
      (llT, pos) = _selectTable(modes >> 6, src, pos, end, _ll,
          zstdPredefinedLlTable, _llFse, _llRle);
      (ofT, pos) = _selectTable((modes >> 4) & 3, src, pos, end, _of,
          zstdPredefinedOfTable, _ofFse, _ofRle);
      (mlT, pos) = _selectTable((modes >> 2) & 3, src, pos, end, _ml,
          zstdPredefinedMlTable, _mlFse, _mlRle);
      _ll = llT;
      _of = ofT;
      _ml = mlT;

      final br = _br;
      if (!br.init(src, pos, end)) {
        throw ZstdFormatError('Corrupt sequences bitstream');
      }

      final llBase = llT.baseValue;
      final llExtra = llT.extraBits;
      final llNext = llT.stateBase;
      final llNb = llT.nbBits;
      final ofBase = ofT.baseValue;
      final ofExtra = ofT.extraBits;
      final ofNext = ofT.stateBase;
      final ofNb = ofT.nbBits;
      final mlBase = mlT.baseValue;
      final mlExtra = mlT.extraBits;
      final mlNext = mlT.stateBase;
      final mlNb = mlT.nbBits;

      var llState = br.readBits(llT.accuracyLog);
      var ofState = br.readBits(ofT.accuracyLog);
      var mlState = br.readBits(mlT.accuracyLog);
      var rep1 = _rep1;
      var rep2 = _rep2;
      var rep3 = _rep3;
      // Below this, an overlapping match cannot be copied a word at a time.
      const minWordOffset = ZstdBitReader.has64BitInts ? 8 : 4;

      for (var remaining = nbSeq - 1;; remaining--) {
        var offset = ofBase[ofState] + br.readBits(ofExtra[ofState]);
        final ml = mlBase[mlState] + br.readBits(mlExtra[mlState]);
        final ll = llBase[llState] + br.readBits(llExtra[llState]);

        if (offset > 3) {
          offset -= 3;
          rep3 = rep2;
          rep2 = rep1;
          rep1 = offset;
        } else {
          // A repeat offset. With no literals before the match, the first
          // choice would be pointless, so each choice moves down by one.
          final index = ll == 0 ? offset : offset - 1;
          if (index == 0) {
            offset = rep1;
          } else if (index == 1) {
            offset = rep2;
            rep2 = rep1;
            rep1 = offset;
          } else {
            offset = index == 2 ? rep3 : rep1 - 1;
            rep3 = rep2;
            rep2 = rep1;
            rep1 = offset;
          }
        }

        if (remaining != 0) {
          llState = llNext[llState] + br.readBits(llNb[llState]);
          mlState = mlNext[mlState] + br.readBits(mlNb[mlState]);
          ofState = ofNext[ofState] + br.readBits(ofNb[ofState]);
        }

        // Execute the sequence: the literals, then the match. The copies may
        // run into the slack past the block's limit, and past the literals.
        if (lp + ll > le) {
          throw ZstdFormatError('Sequence uses more literals than decoded');
        }
        if (op + ll + ml > limit) {
          throw ZstdFormatError('Block decodes past its maximum size');
        }
        if (ll != 0) {
          if (ll < _longCopy) {
            _wildCopy(winData, op, litData, lp, ll);
          } else {
            win.setRange(op, op + ll, lit, lp);
          }
          op += ll;
          lp += ll;
        }

        if (offset > op || offset == 0) {
          throw ZstdFormatError('Match offset $offset out of range');
        }
        final from = op - offset;
        if (offset >= minWordOffset) {
          if (ml < _longCopy || offset < ml) {
            // An overlapping match repeats what it copies, which a word at a
            // time does correctly as long as a word fits in the offset.
            _wildCopy(winData, op, winData, from, ml);
          } else {
            win.setRange(op, op + ml, win, from);
          }
        } else {
          for (var i = 0; i < ml; i++) {
            win[op + i] = win[from + i];
          }
        }
        op += ml;

        if (remaining == 0) {
          break;
        }
      }

      if (!br.isFinished) {
        throw ZstdFormatError('Sequences bitstream not fully consumed');
      }
      _rep1 = rep1;
      _rep2 = rep2;
      _rep3 = rep3;
    } else if (pos != end) {
      throw ZstdFormatError('Data after an empty sequences section');
    }

    // Whatever literals the sequences left over
    final rest = le - lp;
    if (op + rest > limit) {
      throw ZstdFormatError('Block decodes past its maximum size');
    }
    win.setRange(op, op + rest, lit, lp);
    _pos = op + rest;
  }
}

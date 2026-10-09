import 'dart:typed_data';

import 'zstd_bit_writer.dart';
import 'zstd_frame_decoder.dart';
import 'zstd_fse.dart';
import 'zstd_fse_encoder.dart';
import 'zstd_huffman_encoder.dart';

/// The most sequences a block can hold: every match is at least three bytes.
const int zstdMaxSequences = zstdBlockSizeMax ~/ 3 + 1;

/// The sequences a match finder found in one block, and its literals.
class ZstdSequenceStore {
  final Uint8List literals = Uint8List(zstdBlockSizeMax);
  int literalCount = 0;

  final Int32List literalLengths = Int32List(zstdMaxSequences);
  final Int32List matchLengths = Int32List(zstdMaxSequences);

  /// The actual distance of each match, not yet turned into repeat codes.
  final Int32List offsets = Int32List(zstdMaxSequences);
  int count = 0;

  void reset() {
    literalCount = 0;
    count = 0;
  }

  /// Adds a sequence: [literalLength] literals from [src] at [literalStart],
  /// then a match of [matchLength] bytes [offset] back.
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void add(Uint8List src, int literalStart, int literalLength, int offset,
      int matchLength) {
    if (literalLength > 0) {
      literals.setRange(
          literalCount, literalCount + literalLength, src, literalStart);
      literalCount += literalLength;
    }
    literalLengths[count] = literalLength;
    offsets[count] = offset;
    matchLengths[count] = matchLength;
    count++;
  }

  /// Adds the literals after the last match.
  void addLastLiterals(Uint8List src, int start, int length) {
    literals.setRange(literalCount, literalCount + length, src, start);
    literalCount += length;
  }
}

// The four ways a sequence field's table can be given.
const int _modePredefined = 0;
const int _modeRle = 1;
const int _modeCompressed = 2;
const int _modeRepeat = 3;

// What a block encoded a sequence field with, kept so the next block can
// repeat it.
class _FieldTable {
  ZstdFseEncoder? table;
  int rleSymbol = -1;

  bool get isSet => table != null || rleSymbol >= 0;

  void copyFrom(_FieldTable other) {
    table = other.table;
    rleSymbol = other.rleSymbol;
  }
}

// One of the three sequence fields: its codes' histogram, the table chosen
// for the current block and the one in force from before it.
class _Field {
  final int maxCode;
  final int maxLog;
  final List<int> defaultNorm;
  final int defaultLog;
  final ZstdFseEncoder predefined;

  final Uint8List codes = Uint8List(zstdMaxSequences);
  final Uint32List counts = Uint32List(64);

  // The committed table, and the one this block would leave in force.
  final _FieldTable previous = _FieldTable();
  final _FieldTable pending = _FieldTable();

  // Tables built for a block are written into one of two encoders, so that
  // the one in force from before stays intact for repeating.
  ZstdFseEncoder _spare;
  ZstdFseEncoder _owned;

  int mode = 0;
  ZstdFseEncoder? encoder;

  _Field(this.maxCode, this.maxLog, this.defaultNorm, this.defaultLog)
      : predefined = ZstdFseEncoder(defaultLog)
          ..build(defaultNorm, defaultNorm.length, defaultLog),
        _spare = ZstdFseEncoder(maxLog),
        _owned = ZstdFseEncoder(maxLog);

  void reset() {
    previous
      ..table = null
      ..rleSymbol = -1;
  }

  void commit() {
    if (mode == _modeCompressed) {
      // The spare now holds the table in force; the old one becomes spare.
      final t = _owned;
      _owned = _spare;
      _spare = t;
    }
    previous.copyFrom(pending);
  }
}

/// Encodes the literals and sequences of a block.
class ZstdBlockEncoder {
  /// Where [compress] writes the block. Larger than any block can need, as a
  /// block that comes out too large is stored raw instead.
  final Uint8List out = Uint8List(6 * zstdBlockSizeMax);

  final ZstdBitWriter _writer = ZstdBitWriter();
  final ZstdHuffmanEncoder _huffman = ZstdHuffmanEncoder();
  final Uint32List _literalCounts = Uint32List(256);
  final Uint8List _scratch = Uint8List(1024);
  final Int16List _norm = Int16List(64);

  final _Field _ll =
      _Field(zstdMaxLlCode, zstdLlMaxLog, zstdLlDefaultNorm, zstdLlDefaultLog);
  final _Field _of =
      _Field(zstdMaxOfCode, zstdOfMaxLog, zstdOfDefaultNorm, zstdOfDefaultLog);
  final _Field _ml =
      _Field(zstdMaxMlCode, zstdMlMaxLog, zstdMlDefaultNorm, zstdMlDefaultLog);

  // The values of each sequence's extra bits.
  final Int32List _llExtra = Int32List(zstdMaxSequences);
  final Int32List _mlExtra = Int32List(zstdMaxSequences);
  final Int32List _ofExtra = Int32List(zstdMaxSequences);

  int _rep1 = 1;
  int _rep2 = 4;
  int _rep3 = 8;
  int _pendingRep1 = 1;
  int _pendingRep2 = 4;
  int _pendingRep3 = 8;

  /// Starts a new frame, which forgets the tables and repeat offsets.
  void reset() {
    _rep1 = 1;
    _rep2 = 4;
    _rep3 = 8;
    _ll.reset();
    _of.reset();
    _ml.reset();
  }

  /// Makes what the last [compress] did the state the next block starts
  /// from, once that block has been written compressed. If it is stored raw
  /// instead, the decoder never sees it, and this must not be called.
  void commit() {
    _rep1 = _pendingRep1;
    _rep2 = _pendingRep2;
    _rep3 = _pendingRep3;
    _ll.commit();
    _of.commit();
    _ml.commit();
  }

  /// Compresses [seqs] into [out], returning the size, or -1 if the block
  /// would not come out smaller than the [blockLength] bytes it holds.
  int compress(ZstdSequenceStore seqs, int blockLength) {
    var pos = _writeLiterals(seqs.literals, seqs.literalCount, 0);
    if (pos >= blockLength) {
      return -1;
    }
    pos = _writeSequences(seqs, pos);
    return pos >= blockLength ? -1 : pos;
  }

  int _writeLiterals(Uint8List lit, int n, int pos) {
    final out = this.out;
    if (n == 0) {
      out[pos] = 0;
      return pos + 1;
    }

    var same = true;
    final first = lit[0];
    for (var i = 1; i < n; i++) {
      if (lit[i] != first) {
        same = false;
        break;
      }
    }
    if (same && n > 1) {
      pos = _writeRawHeader(1, n, pos);
      out[pos] = first;
      return pos + 1;
    }
    if (n < 64) {
      return _writeRaw(lit, n, pos);
    }

    final counts = _literalCounts..fillRange(0, 256, 0);
    for (var i = 0; i < n; i++) {
      counts[lit[i]]++;
    }
    var maxSymbol = 255;
    while (counts[maxSymbol] == 0) {
      maxSymbol--;
    }

    final huffman = _huffman..build(counts, maxSymbol);
    final headerSize = n < 1024 ? 3 : (n < 16384 ? 4 : 5);
    final singleStream = n < 256;
    final minGain = (n >> 6) + 2;
    final start = pos + headerSize;
    final streamsStart = huffman.writeDescription(out, start, _writer);
    if (streamsStart < 0) {
      return _writeRaw(lit, n, pos);
    }
    final estimate = streamsStart -
        start +
        ((huffman.bitsFor(counts) + 7) >> 3) +
        (singleStream ? 0 : 6);
    if (estimate >= n - minGain) {
      return _writeRaw(lit, n, pos);
    }
    final end = huffman.writeStreams(
        lit, 0, n, out, streamsStart, !singleStream, _writer);
    final compressed = end - start;
    if (compressed >= n - minGain) {
      return _writeRaw(lit, n, pos);
    }

    final sizeFormat = singleStream ? 0 : headerSize - 2;
    final sizeBits = const [0, 0, 0, 10, 14, 18][headerSize];
    // Up to 40 bits, so assembled by arithmetic rather than shifts, which
    // would truncate where ints are JavaScript numbers.
    var header = 2 + sizeFormat * 4 + n * 16 + compressed * _pow2(4 + sizeBits);
    for (var i = 0; i < headerSize; i++) {
      out[pos + i] = header % 256;
      header ~/= 256;
    }
    return end;
  }

  static int _pow2(int n) => n < 31 ? 1 << n : (1 << 30) * (1 << (n - 30));

  int _writeRaw(Uint8List lit, int n, int pos) {
    pos = _writeRawHeader(0, n, pos);
    out.setRange(pos, pos + n, lit);
    return pos + n;
  }

  // The header of raw or RLE literals, [type] 0 or 1.
  int _writeRawHeader(int type, int n, int pos) {
    final out = this.out;
    if (n < 32) {
      out[pos] = type | (n << 3);
      return pos + 1;
    }
    if (n < 4096) {
      final v = type | (1 << 2) | (n << 4);
      out[pos] = v & 0xff;
      out[pos + 1] = v >> 8;
      return pos + 2;
    }
    final v = type | (3 << 2) | (n << 4);
    out[pos] = v & 0xff;
    out[pos + 1] = (v >> 8) & 0xff;
    out[pos + 2] = v >> 16;
    return pos + 3;
  }

  static final Uint8List _llCodeTable = _codeTable(zstdLlBase, 64, 0);
  static final Uint8List _mlCodeTable = _codeTable(zstdMlBase, 128, 3);

  // For each value below [size], the largest code whose baseline, less
  // [bias], is no greater.
  static Uint8List _codeTable(List<int> base, int size, int bias) {
    final t = Uint8List(size);
    var code = 0;
    for (var v = 0; v < size; v++) {
      while (code + 1 < base.length && base[code + 1] - bias <= v) {
        code++;
      }
      t[v] = code;
    }
    return t;
  }

  int _writeSequences(ZstdSequenceStore seqs, int pos) {
    final out = this.out;
    final n = seqs.count;
    if (n < 128) {
      out[pos++] = n;
    } else if (n < 0x7F00) {
      out[pos++] = (n >> 8) + 128;
      out[pos++] = n & 0xff;
    } else {
      out[pos++] = 255;
      out[pos++] = (n - 0x7F00) & 0xff;
      out[pos++] = (n - 0x7F00) >> 8;
    }
    _pendingRep1 = _rep1;
    _pendingRep2 = _rep2;
    _pendingRep3 = _rep3;
    if (n == 0) {
      _ll.pending.copyFrom(_ll.previous);
      _of.pending.copyFrom(_of.previous);
      _ml.pending.copyFrom(_ml.previous);
      _ll.mode = _of.mode = _ml.mode = _modeRepeat;
      return pos;
    }

    _computeCodes(seqs);

    final modesPos = pos++;
    pos = _chooseTable(_ll, n, pos);
    pos = _chooseTable(_of, n, pos);
    pos = _chooseTable(_ml, n, pos);
    out[modesPos] = (_ll.mode << 6) | (_of.mode << 4) | (_ml.mode << 2);

    return _writeBitstream(n, pos);
  }

  // Turns the offsets into repeat codes where it can, as the decoder will
  // read them, and works out every field's code and extra bits.
  void _computeCodes(ZstdSequenceStore seqs) {
    final n = seqs.count;
    var rep1 = _pendingRep1;
    var rep2 = _pendingRep2;
    var rep3 = _pendingRep3;
    final llCodes = _ll.codes;
    final mlCodes = _ml.codes;
    final ofCodes = _of.codes;
    final llCounts = _ll.counts..fillRange(0, 64, 0);
    final mlCounts = _ml.counts..fillRange(0, 64, 0);
    final ofCounts = _of.counts..fillRange(0, 64, 0);

    for (var i = 0; i < n; i++) {
      final ll = seqs.literalLengths[i];
      final ml = seqs.matchLengths[i];
      final offset = seqs.offsets[i];

      // The offset value: a repeat code from 1 to 3, or the offset plus 3.
      // With no literals the repeat codes move down one, the decoder taking
      // code 1 to mean the second offset and code 3 the first less one.
      int value;
      if (ll != 0 && offset == rep1) {
        value = 1;
      } else if (offset == rep2) {
        value = ll != 0 ? 2 : 1;
        rep2 = rep1;
        rep1 = offset;
      } else if (offset == rep3) {
        value = ll != 0 ? 3 : 2;
        rep3 = rep2;
        rep2 = rep1;
        rep1 = offset;
      } else if (ll == 0 && offset == rep1 - 1) {
        value = 3;
        rep3 = rep2;
        rep2 = rep1;
        rep1 = offset;
      } else {
        value = offset + 3;
        rep3 = rep2;
        rep2 = rep1;
        rep1 = offset;
      }

      final llCode = ll < 64 ? _llCodeTable[ll] : ll.bitLength + 18;
      final mlBase = ml - 3;
      final mlCode =
          mlBase < 128 ? _mlCodeTable[mlBase] : mlBase.bitLength + 35;
      final ofCode = value.bitLength - 1;
      llCodes[i] = llCode;
      mlCodes[i] = mlCode;
      ofCodes[i] = ofCode;
      llCounts[llCode]++;
      mlCounts[mlCode]++;
      ofCounts[ofCode]++;
      _llExtra[i] = ll - zstdLlBase[llCode];
      _mlExtra[i] = ml - zstdMlBase[mlCode];
      _ofExtra[i] = value - (1 << ofCode);
    }
    _pendingRep1 = rep1;
    _pendingRep2 = rep2;
    _pendingRep3 = rep3;
  }

  // Chooses how to give [field]'s table, writes what that mode needs at
  // [pos] and returns the position after it.
  int _chooseTable(_Field field, int n, int pos) {
    final counts = field.counts;
    var maxSymbol = field.maxCode;
    while (counts[maxSymbol] == 0) {
      maxSymbol--;
    }
    var mostFrequent = 0;
    var mostFrequentSymbol = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      if (counts[s] > mostFrequent) {
        mostFrequent = counts[s];
        mostFrequentSymbol = s;
      }
    }
    final defaultAllowed = maxSymbol < field.defaultNorm.length;
    final previous = field.previous;

    if (mostFrequent == n) {
      if (defaultAllowed && n <= 2) {
        return _useTable(field, _modePredefined, field.predefined, pos);
      }
      if (previous.table == null && previous.rleSymbol == mostFrequentSymbol) {
        field
          ..mode = _modeRepeat
          ..encoder = null
          ..pending.copyFrom(previous);
        return pos;
      }
      field
        ..mode = _modeRle
        ..encoder = null
        ..pending.table = null
        ..pending.rleSymbol = mostFrequentSymbol;
      out[pos] = mostFrequentSymbol;
      return pos + 1;
    }

    var bestMode = -1;
    var bestCost = double.infinity;
    if (defaultAllowed) {
      final c = field.predefined.cost(counts, maxSymbol);
      if (c != null) {
        bestMode = _modePredefined;
        bestCost = c;
      }
    }
    if (previous.table != null) {
      final c = previous.table!.cost(counts, maxSymbol);
      if (c != null && c <= bestCost) {
        bestMode = _modeRepeat;
        bestCost = c;
      }
    }

    // A new table, if its description pays for itself
    final log = zstdFseTableLog(n, maxSymbol, field.maxLog);
    final numSymbols = zstdFseNormalize(counts, maxSymbol, n, log, _norm);
    final descriptionEnd =
        zstdFseWriteDescription(_scratch, 0, _norm, numSymbols, log, _writer);
    final newCost = zstdFseCost(counts, maxSymbol, _norm, numSymbols, log)! +
        descriptionEnd * 8;
    if (newCost < bestCost) {
      final table = field._spare..build(_norm, numSymbols, log);
      out.setRange(pos, pos + descriptionEnd, _scratch);
      field
        ..mode = _modeCompressed
        ..encoder = table
        ..pending.table = table
        ..pending.rleSymbol = -1;
      return pos + descriptionEnd;
    }
    if (bestMode == _modeRepeat) {
      field
        ..mode = _modeRepeat
        ..encoder = previous.table
        ..pending.copyFrom(previous);
      return pos;
    }
    return _useTable(field, _modePredefined, field.predefined, pos);
  }

  int _useTable(_Field field, int mode, ZstdFseEncoder table, int pos) {
    field
      ..mode = mode
      ..encoder = table
      ..pending.table = table
      ..pending.rleSymbol = -1;
    return pos;
  }

  // Writes the sequences' bitstream, last sequence first, so that the decoder
  // reading it backwards meets the first sequence first.
  int _writeBitstream(int n, int pos) {
    final writer = _writer..reset(out, pos);
    final llCodes = _ll.codes;
    final mlCodes = _ml.codes;
    final ofCodes = _of.codes;
    final llT = _ll.encoder;
    final mlT = _ml.encoder;
    final ofT = _of.encoder;

    var last = n - 1;
    var llState = llT?.initState(llCodes[last]) ?? 0;
    var mlState = mlT?.initState(mlCodes[last]) ?? 0;
    var ofState = ofT?.initState(ofCodes[last]) ?? 0;
    writer.addBits(_llExtra[last], zstdLlBits[llCodes[last]]);
    writer.addBits(_mlExtra[last], zstdMlBits[mlCodes[last]]);
    writer.addBits(_ofExtra[last], ofCodes[last]);

    for (var i = n - 2; i >= 0; i--) {
      final llCode = llCodes[i];
      final mlCode = mlCodes[i];
      final ofCode = ofCodes[i];
      if (ofT != null) {
        ofState = ofT.encode(writer, ofState, ofCode);
      }
      if (mlT != null) {
        mlState = mlT.encode(writer, mlState, mlCode);
      }
      if (llT != null) {
        llState = llT.encode(writer, llState, llCode);
      }
      writer.addBits(_llExtra[i], zstdLlBits[llCode]);
      writer.addBits(_mlExtra[i], zstdMlBits[mlCode]);
      writer.addBits(_ofExtra[i], ofCode);
    }
    mlT?.flush(writer, mlState);
    ofT?.flush(writer, ofState);
    llT?.flush(writer, llState);
    return writer.closeBackward();
  }
}

import 'dart:typed_data';

import '../../util/output_stream.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_ldm.dart';
import 'zstd_level_params.dart';
import 'zstd_literals_encoder.dart';
import 'zstd_match_finder.dart';
import 'zstd_seq_splitter.dart';
import 'zstd_sequences_encoder.dart';
import 'zstd_web.dart';

/// Writes the blocks of one frame: a repeated byte, an entropy coded block of
/// literals and sequences, or the bytes as they stand, whichever is smallest
class ZstdBlockEncoder {
  final ZstdLiteralsEncoder _literals = ZstdLiteralsEncoder();
  final ZstdMatchFinder _finder;
  final ZstdSequenceStore _store;
  final ZstdSequencesEncoder _sequences;
  final ZstdSeqSplitter _splitter = ZstdSeqSplitter();
  final Uint8List _scratch;

  /// The long distance matcher, which only the widest window of the hardest
  /// searching levels turns on, and the matches it finds for one block
  final ZstdLdm? _ldm;
  final ZstdLdmSequences? _ldmSeq;

  /// `ZSTD_resolveBlockSplitterMode`: only the optimal parses over a window
  /// this wide cut a block up after parsing it
  final bool _splitting;

  /// The offsets as the decoder will see them and as the sequences imply, which
  /// a partition sent raw or as one repeated byte pulls apart
  final Uint32List _decoded = Uint32List(3);
  final Uint32List _coded = Uint32List(3);
  final Uint32List _saved = Uint32List(3);

  /// `ZSTD_minGain`'s shift for this level
  final int _gainLog;

  /// The reference will not open a frame with a repeated byte block, since a
  /// decoder before 1.4.4 reads one as the frame ending early
  bool _first = true;

  /// `ZSTD_referenceExternalSequences`: matches found once for a whole job
  final ZstdLdmSequences? _external;

  ZstdBlockEncoder(int blockSizeMax, ZstdLevelParams params)
      : this._(blockSizeMax, params,
            ZstdLdm.forParams(params.refStrategy, params.windowLog), null);

  /// The matcher is off here, [external] holds the sequences it would find
  ZstdBlockEncoder.external(
      int blockSizeMax, ZstdLevelParams params, ZstdLdmSequences? external)
      : this._(blockSizeMax, params, null, external);

  ZstdBlockEncoder._(
      int blockSizeMax, ZstdLevelParams params, this._ldm, this._external)
      : _ldmSeq = _ldm == null
            ? null
            : ZstdLdmSequences(_ldm.capacityFor(blockSizeMax)),
        _finder = ZstdMatchFinder(params),
        _store = ZstdSequenceStore(blockSizeMax,
            minMatch: params.hashBytes == 3 ? 3 : 4),
        _sequences = ZstdSequencesEncoder(),
        _scratch = Uint8List(blockSizeMax + (blockSizeMax >> 1) + 1024),
        _splitting =
            params.strategy == zstdStrategyOptimal && params.windowLog >= 17,
        _gainLog = zstdGainLog(params) {
    _sequences.strategy = params.strategy;
    _literals.minSize = zstdMinLiteralsToCompress(params);
    _literals.disabled =
        params.strategy == zstdStrategyFast && params.targetLength > 0;
    _literals.gainLog = zstdGainLog(params);
    _literals.cheapRepeat = params.strategy < zstdStrategyLazy;
    _literals.optimalDepth =
        params.strategy == zstdStrategyOptimal && params.depth >= 2;
    _finder.reset();
  }

  /// Loads a dictionary's content into the tables the parse searches. The first
  /// block reaches into it that way
  void prime(Uint8List src, int start, int end, ZstdDictionary dictionary) {
    _finder.prefixStart = end;
    _finder.prime(src, start, end);
    _ldm?.fill(src, start, end);
    _sequences.loadDictionary(dictionary);
    if (dictionary.hasEntropy) {
      _literals.loadDictionary(
          dictionary.huffmanWeights, dictionary.huffman.tableLog);
      final prices = _finder.prices;
      prices.dictionaryTree = _literals.dictionaryTree;
      prices.dictionaryLitLengths = _sequences.dictionaryLitLengths;
      prices.dictionaryOffsets = _sequences.dictionaryOffsets;
      prices.dictionaryMatchLengths = _sequences.dictionaryMatchLengths;
    }
  }

  /// Loads a raw prefix into the tables. A job of the threaded encoder starts
  /// from it. The bytes stay ordinary contiguous input: no outside
  /// segment, nothing to keep whole, no entropy to repeat
  void primeRawPrefix(Uint8List src, int start, int end) =>
      _finder.primeRaw(src, start, end);

  /// `loadedDictEnd`: where the dictionary this frame was primed with ends,
  /// zero once a block has left it a whole window behind
  int get dictionaryEnd => _finder.dictionaryEnd;

  void dropDictionary() {
    _finder.dictionaryEnd = 0;
  }

  /// `ZSTD_window_update` on input that does not follow the last: what sits
  /// before [at] becomes an outside segment
  void cut(int at) => _finder.cut(at);

  /// What a slide of the source buffer has to be a multiple of for the tables
  /// to survive it
  int get slideStep => _finder.slideStep;

  /// How many entries a slide visits, so a caller can offset the cost with
  /// the bytes it holds spare
  int get slideCost => _finder.slideCost;

  /// Lets a caller drop the front of the buffer once the window has left it
  void slide(int delta) {
    _finder.slide(delta);
    _ldm?.slide(delta);
  }

  void encode(Uint8List src, int start, int end, int lowLimit, OutputStream out,
      bool isLast, Uint32List rep) {
    final first = _first;
    _first = false;
    if (!first) {
      _sequences.dropOffsetTrust();
    }
    final size = end - start;
    if (size > 0) {
      final held0 = rep[0];
      final held1 = rep[1];
      final held2 = rep[2];
      final ldm = _ldm;
      final ldmSeq = _ldmSeq;
      final external = _external;
      if (ldm != null && ldmSeq != null) {
        ldm.generate(src, ByteData.sublistView(src), start, end, ldmSeq);
        _finder.ldm = ldmSeq;
      } else if (external != null) {
        _finder.ldm = external;
      }
      _finder.parse(src, start, end, lowLimit, _store, rep);
      // `ZSTD_ldm_blockCompress` leaves the store one block further on
      external?.skipBytes(size);
      if (_splitting) {
        final splits =
            _splitter.derive(_scratch, _store, _literals, _sequences);
        if (splits > 0) {
          _writeSplit(src, start, size, out, isLast, rep, first, splits, held0,
              held1, held2);
          return;
        }
      }
      final literals = _store.literalsLength;
      final coded =
          _code(src, start, size, 0, _store.count, 0, literals, first);
      if (coded == 1) {
        // Nothing this block built reached the decoder, so none of it is kept
        rep[0] = held0;
        rep[1] = held1;
        rep[2] = held2;
        _writeHeader(out, isLast, zstdBlockRle, size);
        out.writeByte(src[start]);
        return;
      }
      if (coded > 0) {
        _writeHeader(out, isLast, zstdBlockCompressed, coded);
        out.writeRange(_scratch, 0, coded);
        _sequences.commit();
        _literals.commit();
        return;
      }
      // A stored block has no sequences, so the repeat offsets are restored
      rep[0] = held0;
      rep[1] = held1;
      rep[2] = held2;
    }

    _writeHeader(out, isLast, zstdBlockRaw, size);
    if (size > 0) {
      out.writeRange(src, start, end);
    }
  }

  /// `ZSTD_compressBlock_splitBlock_internal`: each partition of the sequence
  /// store becomes its own block, and the offsets passed to the next block are
  /// the ones the decoder will hold rather than the ones the sequences imply
  void _writeSplit(
      Uint8List src,
      int start,
      int size,
      OutputStream out,
      bool isLast,
      Uint32List rep,
      bool first,
      int splits,
      int held0,
      int held1,
      int held2) {
    _decoded[0] = held0;
    _decoded[1] = held1;
    _decoded[2] = held2;
    _coded.setAll(0, _decoded);
    var at = start;
    var covered = 0;
    var from = 0;
    for (var i = 0; i <= splits; i++) {
      final to = _splitter.points[i];
      final litFrom = _store.literalsIn(0, from);
      final literals = _store.literalsIn(from, to);
      final litTo =
          to == _store.count ? _store.literalsLength : litFrom + literals;
      var bytes = literals + _store.matchesIn(from, to);
      covered += bytes;
      final last = i == splits;
      // The trailing literals no match covers land in the final partition
      if (last) {
        bytes += size - covered;
      }
      _saved.setAll(0, _decoded);
      zstdResolveOffCodes(_decoded, _coded, _store, from, to);
      final coded = _code(src, at, bytes, from, to, litFrom, litTo, first);
      final ending = last && isLast;
      if (coded > 1) {
        _writeHeader(out, ending, zstdBlockCompressed, coded);
        out.writeRange(_scratch, 0, coded);
        _sequences.commit();
        _literals.commit();
      } else {
        if (coded == 1) {
          _writeHeader(out, ending, zstdBlockRle, bytes);
          out.writeByte(src[at]);
        } else {
          _writeHeader(out, ending, zstdBlockRaw, bytes);
          out.writeRange(src, at, at + bytes);
        }
        _decoded.setAll(0, _saved);
      }
      at += bytes;
      from = to;
    }
    rep[0] = _decoded[0];
    rep[1] = _decoded[1];
    rep[2] = _decoded[2];
  }

  /// Codes one block or one partition into the scratch buffer. Returns its
  /// size, zero for a block not worth coding and one for a repeated byte
  int _code(Uint8List src, int at, int bytes, int from, int to, int litFrom,
      int litTo, bool first) {
    final count = to - from;
    final literals = litTo - litFrom;
    // `suspectUncompressible`: literals this far ahead of the sequences that
    // broke them up rarely pay for a tree
    final suspect = count == 0 || literals ~/ count >= 20;
    final literalsSize = _literals
        .encode(_scratch, 0, _store.literals, litFrom, litTo, suspect: suspect);
    var coded = literalsSize +
        _sequences.encode(_scratch, literalsSize, _store, from, to);
    // Zero is the reference's own way of saying a coded block is not worth it
    if (coded >= bytes - ((bytes >> _gainLog) + 2)) {
      coded = 0;
    }
    // The reference scans for a repeated byte here, not over every block
    if (!first &&
        coded < _rleWorthTesting &&
        bytes > 1 &&
        _isRepeated(src, at, at + bytes)) {
      return 1;
    }
    return coded;
  }

  /// `rleMaxLength`, above which a block cannot be one repeated byte
  static const _rleWorthTesting = 25;

  static void _writeHeader(OutputStream out, bool isLast, int type, int size) {
    final header = (isLast ? 1 : 0) | (type << 1) | (size << 3);
    out.writeByte(header & 0xff);
    out.writeByte((header >> 8) & 0xff);
    out.writeByte((header >> 16) & 0xff);
  }

  /// Eight bytes at a time: a block that is not one repeated byte usually
  /// differs within its first word, and one that is has to be read whole
  static bool _isRepeated(Uint8List src, int start, int end) {
    final first = src[start];
    if (!zstdUse64Bit) {
      for (var at = start + 1; at < end; at++) {
        if (src[at] != first) return false;
      }
      return true;
    }
    final splat = first * ((0x01010101 << 32) | 0x01010101);
    final view = ByteData.sublistView(src);
    var at = start;
    final limit = end - 8;
    while (at <= limit) {
      if (view.getUint64(at, Endian.little) != splat) {
        return false;
      }
      at += 8;
    }
    while (at < end) {
      if (src[at] != first) {
        return false;
      }
      at++;
    }
    return true;
  }
}

import 'dart:typed_data';

import 'zstd_literals_encoder.dart';
import 'zstd_sequences_encoder.dart';

/// `MIN_SEQUENCES_BLOCK_SPLITTING`, `ZSTD_MAX_NB_BLOCK_SPLITS`,
/// `ZSTD_blockHeaderSize`
const _minSequences = 300;
const _maxSplits = 196;
const _blockHeader = 3;

/// `ZSTD_deriveBlockSplits`: where a block's sequences are better sent as
/// separate blocks, each with its own tables. A window is estimated whole and
/// in halves, and halves that together come out smaller win and recurse
class ZstdSeqSplitter {
  /// One past the last sequence of each partition, the last the whole count
  final Uint32List points = Uint32List(_maxSplits + 2);
  int count = 0;

  late Uint8List _scratch;
  late ZstdSequenceStore _store;
  late ZstdLiteralsEncoder _literals;
  late ZstdSequencesEncoder _sequences;

  /// The number of cuts, zero meaning the block stays whole
  int derive(Uint8List scratch, ZstdSequenceStore store,
      ZstdLiteralsEncoder literals, ZstdSequencesEncoder sequences) {
    count = 0;
    final total = store.count;
    if (total <= 4) {
      return 0;
    }
    _scratch = scratch;
    _store = store;
    _literals = literals;
    _sequences = sequences;
    _search(0, total);
    points[count] = total;
    return count;
  }

  void _search(int start, int end) {
    if (end - start < _minSequences || count >= _maxSplits) {
      return;
    }
    final mid = (start + end) ~/ 2;
    final whole = _estimate(start, end);
    final first = _estimate(start, mid);
    final second = _estimate(mid, end);
    if (first + second < whole) {
      _search(start, mid);
      points[count++] = mid;
      _search(mid, end);
    }
  }

  /// `ZSTD_buildEntropyStatisticsAndEstimateSubBlockSize` over one window
  int _estimate(int start, int end) {
    final from = _store.literalsIn(0, start);
    // Only a window reaching the end of the block has the trailing literals
    final to = end == _store.count
        ? _store.literalsLength
        : from + _store.literalsIn(start, end);
    return _literals.estimate(_scratch, _store.literals, from, to) +
        _sequences.estimate(_scratch, _store, start, end) +
        _blockHeader;
  }
}

/// `ZSTD_updateRep`, where [noLiterals] is true if the literal run was empty
void zstdUpdateRep(Uint32List rep, int offBase, bool noLiterals) {
  if (offBase > 3) {
    rep[2] = rep[1];
    rep[1] = rep[0];
    rep[0] = offBase - 3;
    return;
  }
  final code = offBase - 1 + (noLiterals ? 1 : 0);
  if (code == 0) {
    return;
  }
  final offset = code == 3 ? rep[0] - 1 : rep[code];
  if (code >= 2) {
    rep[2] = rep[1];
  }
  rep[1] = rep[0];
  rep[0] = offset;
}

/// `ZSTD_resolveRepcodeToRawOffset`. Code three with no literals names the
/// first offset less one, which may be zero and is then discarded
int _rawOffset(Uint32List rep, int offBase, bool noLiterals) {
  final code = offBase - 1 + (noLiterals ? 1 : 0);
  return code == 3 ? rep[0] - 1 : rep[code];
}

/// `ZSTD_seqStore_resolveOffCodes`: a partition sent raw or as one repeated
/// byte leaves [decoded], what the decoder will hold, behind [coded], what the
/// sequences imply, so a repeat that resolves differently names its offset
void zstdResolveOffCodes(Uint32List decoded, Uint32List coded,
    ZstdSequenceStore store, int from, int to) {
  final seq = store.seq;
  for (var i = from; i < to; i++) {
    final at = i << 2;
    final offBase = seq[at + 2];
    final noLiterals = seq[at] == 0;
    if (offBase <= 3) {
      final wanted = _rawOffset(coded, offBase, noLiterals);
      if (_rawOffset(decoded, offBase, noLiterals) != wanted) {
        seq[at + 2] = wanted + 3;
      }
    }
    zstdUpdateRep(decoded, seq[at + 2], noLiterals);
    zstdUpdateRep(coded, offBase, noLiterals);
  }
}

import 'dart:typed_data';

import '../../util/archive_exception.dart';
import 'zstd_bit_writer.dart';
import 'zstd_constants.dart';
import 'zstd_fse_encoder.dart';
import 'zstd_web.dart';

class ZstdHuffmanEncoderException extends ArchiveException {
  ZstdHuffmanEncoderException(super.message);
  @override
  String toString() => 'ZstdHuffmanEncoderException: $message';
}

/// Accuracy the weight description is coded at
const _weightLog = 6;

/// Fewer literals than this go into one stream rather than four
const zstdFourStreamsFrom = 256;

/// `HUF_sort`'s buckets: a bucket per count below [_logBucketsFrom] and one per
/// power of two above it, so ordering symbols by count is a two pass scatter
/// rather than a comparison sort, worth 3.1% of the encoder
const _buckets = 192;
const _logBucketsFrom = _buckets - 1 - 32 - 1;
const _distinctCounts = _logBucketsFrom + 7;

/// `kInsertionSortThreshold`
const _insertionFrom = 8;

/// The encoding side of a literals tree: a code and its width per symbol
class ZstdHuffmanEncoder {
  final Uint16List codes = Uint16List(zstdHuffmanSymbolCount);
  final Uint8List widths = Uint8List(zstdHuffmanSymbolCount);

  /// `HUF_flags_optimalDepth`, which the levels from `btultra` up set
  bool optimalDepth = false;

  /// Where a description is written only to be measured
  final Uint8List _probe = Uint8List(1024);

  /// `HUF_CElt`: the code of a symbol and its width in one value, which the
  /// encoding loop reads with a single load
  final Uint32List _elt = Uint32List(zstdHuffmanSymbolCount);
  int tableLog = 0;
  int maxSymbol = 0;

  // The tree is built over symbols sorted by count and internal nodes above
  // them, so one array holds both
  static const _nodeBase = zstdHuffmanSymbolCount + 1;
  final Uint32List _count = Uint32List(_nodeBase * 2);
  final Uint16List _parent = Uint16List(_nodeBase * 2);
  final Uint8List _bits = Uint8List(_nodeBase * 2);
  final Uint16List _symbol = Uint16List(_nodeBase * 2);
  final Uint32List _bucketBase = Uint32List(_buckets);
  final Uint32List _bucketAt = Uint32List(_buckets);
  final Uint32List _rankLast = Uint32List(zstdHuffmanLogMax + 3);
  final Uint16List _perRank = Uint16List(zstdHuffmanLogMax + 1);
  final Uint16List _valueOfRank = Uint16List(zstdHuffmanLogMax + 1);

  /// Builds a tree over [counts], which cover [total] bytes, no code wider than
  /// what `HUF_optimalTableLog` allows. Returns false when fewer than two
  /// symbols are used, and such literals are written as RLE instead
  bool build(Uint32List counts, int total) {
    var used = 0;
    maxSymbol = 0;
    for (var s = 0; s < zstdHuffmanSymbolCount; s++) {
      if (counts[s] != 0) {
        used++;
        maxSymbol = s;
      }
    }
    if (used < 2) {
      return false;
    }

    final log = optimalDepth ? _searchLog(counts, used) : _optimalLog(total);
    _sort(counts);
    final root = _buildTree(used - 1);
    tableLog = _limitHeight(used - 1, log, root);
    _assignCodes(used - 1);
    return true;
  }

  /// `HUF_optimalTableLog`'s own search, which `btultra` and above run in place
  /// of the estimate: every depth from the fewest bits the alphabet needs is
  /// built and described, and the one that comes out smallest wins
  int _searchLog(Uint32List counts, int used) {
    final least = zstdHighestBit(used) + 1;
    var best = 4611686018427387904;
    var log = zstdHuffmanLogMax;
    for (var guess = least; guess <= zstdHuffmanLogMax; guess++) {
      _sort(counts);
      final root = _buildTree(used - 1);
      final height = _limitHeight(used - 1, guess, root);
      if (height < guess && guess > least) {
        break;
      }
      tableLog = height;
      _assignCodes(used - 1);
      final described = writeTable(_probe, 0);
      if (described < 0) {
        continue;
      }
      var bits = 0;
      for (var s = 0; s <= maxSymbol; s++) {
        bits += widths[s] * counts[s];
      }
      final size = (bits >> 3) + described;
      if (size > best + 1) {
        break;
      }
      if (size < best) {
        best = size;
        log = guess;
      }
    }
    return log;
  }

  /// `FSE_optimalTableLog_internal` with a minus of one.
  /// `HUF_optimalTableLog` falls back to it below `btultra`
  int _optimalLog(int total) {
    var log = zstdHuffmanLogMax;
    final fromSize = zstdHighestBit(total - 1) - 1;
    if (fromSize >= 0 && fromSize < log) {
      log = fromSize;
    }
    final bySize = zstdHighestBit(total) + 1;
    final bySymbols = zstdHighestBit(maxSymbol) + 2;
    final least = bySize < bySymbols ? bySize : bySymbols;
    if (least > log) {
      log = least;
    }
    return log < 5 ? 5 : log;
  }

  /// Puts every symbol [counts] gives a tally into `_count` and `_symbol`,
  /// heaviest first and ties in symbol order. `HUF_sort`
  void _sort(Uint32List counts) {
    _bucketBase.fillRange(0, _buckets, 0);
    for (var s = 0; s <= maxSymbol; s++) {
      final seen = counts[s];
      if (seen != 0) {
        _bucketBase[_bucketOf(seen)]++;
      }
    }
    for (var b = _buckets - 1; b > 0; b--) {
      final above = _bucketBase[b];
      _bucketBase[b - 1] += above;
      _bucketAt[b] = above;
    }
    for (var s = 0; s <= maxSymbol; s++) {
      final seen = counts[s];
      if (seen != 0) {
        final at = _bucketAt[_bucketOf(seen) + 1]++;
        _count[at] = seen;
        _symbol[at] = s;
      }
    }
    for (var b = _distinctCounts; b < _buckets - 1; b++) {
      if (_bucketAt[b] - _bucketBase[b] > 1) {
        _quickSort(_bucketBase[b], _bucketAt[b] - 1);
      }
    }
  }

  @pragma('vm:prefer-inline')
  static int _bucketOf(int count) => count < _distinctCounts
      ? count
      : zstdHighestBitFast(count) + _logBucketsFrom;

  /// `HUF_simpleQuickSort`. Its partition is not stable, so which of two
  /// symbols of equal count ends up with the shorter code is decided here and
  /// an insertion sort in its place writes a different archive
  void _quickSort(int low, int high) {
    if (high - low < _insertionFrom) {
      _insertionSort(low, high);
      return;
    }
    var from = low;
    var to = high;
    while (from < to) {
      final at = _partition(from, to);
      if (at - from < to - at) {
        _quickSort(from, at - 1);
        from = at + 1;
      } else {
        _quickSort(at + 1, to);
        to = at - 1;
      }
    }
  }

  void _insertionSort(int low, int high) {
    for (var i = low + 1; i <= high; i++) {
      final seen = _count[i];
      final symbol = _symbol[i];
      var at = i;
      while (at > low && _count[at - 1] < seen) {
        _count[at] = _count[at - 1];
        _symbol[at] = _symbol[at - 1];
        at--;
      }
      _count[at] = seen;
      _symbol[at] = symbol;
    }
  }

  /// The rightmost element is the pivot, which the reference settled on
  int _partition(int low, int high) {
    final pivot = _count[high];
    var at = low - 1;
    for (var j = low; j < high; j++) {
      if (_count[j] > pivot) {
        at++;
        _swap(at, j);
      }
    }
    _swap(at + 1, high);
    return at + 1;
  }

  void _swap(int a, int b) {
    final count = _count[a];
    final symbol = _symbol[a];
    _count[a] = _count[b];
    _symbol[a] = _symbol[b];
    _count[b] = count;
    _symbol[b] = symbol;
  }

  /// Merges the two cheapest nodes until one is left, taking them from either
  /// the sorted symbols or the nodes built so far, whichever is cheaper
  int _buildTree(int lastSymbol) {
    var nodeNb = _nodeBase;
    var lowS = lastSymbol;
    final root = nodeNb + lowS - 1;
    var lowN = nodeNb;

    _count[nodeNb] = _count[lowS] + _count[lowS - 1];
    _parent[lowS] = nodeNb;
    _parent[lowS - 1] = nodeNb;
    nodeNb++;
    lowS -= 2;
    for (var n = nodeNb; n <= root; n++) {
      _count[n] = 1 << 30;
    }

    while (nodeNb <= root) {
      final a = _pick(lowS, lowN);
      if (a == lowS) {
        lowS--;
      } else {
        lowN++;
      }
      final b = _pick(lowS, lowN);
      if (b == lowS) {
        lowS--;
      } else {
        lowN++;
      }
      _count[nodeNb] = _count[a] + _count[b];
      _parent[a] = nodeNb;
      _parent[b] = nodeNb;
      nodeNb++;
    }

    _bits[root] = 0;
    for (var n = root - 1; n >= _nodeBase; n--) {
      _bits[n] = _bits[_parent[n]] + 1;
    }
    for (var n = 0; n <= lastSymbol; n++) {
      _bits[n] = _bits[_parent[n]] + 1;
    }
    return root;
  }

  @pragma('vm:prefer-inline')
  int _pick(int lowS, int lowN) =>
      (lowS >= 0 && _count[lowS] < _count[lowN]) ? lowS : lowN;

  /// Flattens anything wider than [target] and pays the debt back by widening
  /// the cheapest symbols, one rank at a time
  int _limitHeight(int lastSymbol, int target, int root) {
    final largest = _bits[lastSymbol];
    if (largest <= target) {
      return largest;
    }

    var cost = 0;
    final baseCost = 1 << (largest - target);
    var n = lastSymbol;
    while (_bits[n] > target) {
      cost += baseCost - (1 << (largest - _bits[n]));
      _bits[n] = target;
      n--;
    }
    while (n >= 0 && _bits[n] == target) {
      n--;
    }
    cost >>= largest - target;

    const noSymbol = 0xffffffff;
    for (var i = 0; i < _rankLast.length; i++) {
      _rankLast[i] = noSymbol;
    }
    var width = target;
    for (var pos = n; pos >= 0; pos--) {
      if (_bits[pos] >= width) {
        continue;
      }
      width = _bits[pos];
      _rankLast[target - width] = pos;
    }

    while (cost > 0) {
      // One symbol a rank up costs the same as two a rank below it, so take
      // whichever of the two is cheaper by count
      var step = zstdHighestBit(cost) + 1;
      for (; step > 1; step--) {
        final high = _rankLast[step];
        final low = _rankLast[step - 1];
        if (high == noSymbol) {
          continue;
        }
        if (low == noSymbol) {
          break;
        }
        if (_count[high] <= 2 * _count[low]) {
          break;
        }
      }
      while (step < _rankLast.length && _rankLast[step] == noSymbol) {
        step++;
      }
      if (step >= _rankLast.length) {
        throw ZstdHuffmanEncoderException('No rank left to widen');
      }
      cost -= 1 << (step - 1);
      final pos = _rankLast[step];
      _bits[pos]++;

      if (_rankLast[step - 1] == noSymbol) {
        _rankLast[step - 1] = pos;
      }
      if (pos == 0) {
        _rankLast[step] = noSymbol;
      } else {
        _rankLast[step] = pos - 1;
        if (_bits[pos - 1] != target - step) {
          _rankLast[step] = noSymbol;
        }
      }
    }

    // Widening one rank at a time can pay back more than was owed, and the way
    // to give it back without overshooting again is to narrow the cheapest
    // symbols of the widest rank, one at a time
    while (cost < 0) {
      if (_rankLast[1] == noSymbol) {
        while (_bits[n] == target) {
          n--;
        }
        _bits[n + 1]--;
        _rankLast[1] = n + 1;
        cost++;
        continue;
      }
      _bits[_rankLast[1] + 1]--;
      _rankLast[1]++;
      cost++;
    }
    return target;
  }

  /// Canonical codes: the widest rank starts at zero and each rank up starts
  /// where the one below ended, halved
  void _assignCodes(int lastSymbol) {
    for (var i = 0; i <= tableLog; i++) {
      _perRank[i] = 0;
    }
    for (var n = 0; n <= lastSymbol; n++) {
      _perRank[_bits[n]]++;
    }
    var next = 0;
    for (var n = tableLog; n > 0; n--) {
      _valueOfRank[n] = next;
      next += _perRank[n];
      next >>= 1;
    }
    for (var s = 0; s < zstdHuffmanSymbolCount; s++) {
      widths[s] = 0;
      codes[s] = 0;
      _elt[s] = 0;
    }
    for (var n = 0; n <= lastSymbol; n++) {
      widths[_symbol[n]] = _bits[n];
    }
    for (var s = 0; s <= maxSymbol; s++) {
      final width = widths[s];
      if (width != 0) {
        final code = _valueOfRank[width]++;
        codes[s] = code;
        _elt[s] = code | (width << 16);
      }
    }
  }

  /// `HUF_readCTable`: the tree a dictionary described, taken as weights rather
  /// than built from counting a block
  void loadWeights(Uint8List weights, int log) {
    tableLog = log;
    maxSymbol = weights.length - 1;
    for (var s = 0; s < zstdHuffmanSymbolCount; s++) {
      widths[s] = 0;
      codes[s] = 0;
      _elt[s] = 0;
    }
    _perRank.fillRange(0, _perRank.length, 0);
    for (var s = 0; s < weights.length; s++) {
      final w = weights[s];
      if (w != 0) {
        final width = log + 1 - w;
        widths[s] = width;
        _perRank[width]++;
      }
    }
    var next = 0;
    for (var n = log; n > 0; n--) {
      _valueOfRank[n] = next;
      next += _perRank[n];
      next >>= 1;
    }
    for (var s = 0; s < weights.length; s++) {
      final width = widths[s];
      if (width != 0) {
        final code = _valueOfRank[width]++;
        codes[s] = code;
        _elt[s] = code | (width << 16);
      }
    }
  }

  /// `HUF_getNbBitsFromCTable`: how wide this symbol's code is, zero above the
  /// tree's own top symbol
  int bitsOf(int symbol) => symbol > maxSymbol ? 0 : widths[symbol];

  /// Writes the tree description at [at] and returns the bytes it took, or -1
  /// when neither form fits, and then the literals are stored raw
  int writeTable(Uint8List out, int at) {
    final weights = Uint8List(maxSymbol);
    for (var s = 0; s < maxSymbol; s++) {
      weights[s] = widths[s] == 0 ? 0 : tableLog + 1 - widths[s];
    }

    final compressed = _compressWeights(out, at + 1, weights);
    if (compressed > 1 && compressed < maxSymbol ~/ 2) {
      out[at] = compressed;
      return compressed + 1;
    }
    // The direct form has no room to name a symbol above 128
    if (maxSymbol > 128) {
      return -1;
    }
    out[at] = 128 + maxSymbol - 1;
    for (var s = 0; s < maxSymbol; s += 2) {
      final low = s + 1 < maxSymbol ? weights[s + 1] : 0;
      out[at + 1 + (s >> 1)] = (weights[s] << 4) | low;
    }
    return ((maxSymbol + 1) >> 1) + 1;
  }

  /// The weights are themselves FSE coded, two states interleaved, the way the
  /// reader expects. Returns 0 when that is not worth doing
  int _compressWeights(Uint8List out, int at, Uint8List weights) {
    final size = weights.length;
    if (size <= 2) {
      return 0;
    }
    final counts = Uint32List(zstdHuffmanLogMax + 2);
    var maxWeight = 0;
    var most = 0;
    for (var i = 0; i < size; i++) {
      final w = weights[i];
      counts[w]++;
      if (w > maxWeight) {
        maxWeight = w;
      }
    }
    for (var w = 0; w <= maxWeight; w++) {
      if (counts[w] > most) {
        most = counts[w];
      }
    }
    if (most == size || most == 1) {
      return 0;
    }

    final log = zstdOptimalTableLog(_weightLog, size, maxWeight);
    final normalized = Int16List(maxWeight + 1);
    if (!zstdNormalizeCount(normalized, counts, size, maxWeight, log,
        useLowProbCount: false)) {
      return 0;
    }
    var write = at;
    write += zstdWriteNCount(out, write, normalized, maxWeight, log);

    final table = ZstdFseCTable(log, maxWeight + 1);
    table.build(normalized, maxWeight, log, Uint8List(1 << log),
        Uint16List(maxWeight + 1), Uint32List(maxWeight + 2));

    final writer = ZstdBitWriter(ByteData.sublistView(out), write);
    var ip = size;
    int state1;
    int state2;
    if (size & 1 != 0) {
      state1 = table.initialState(weights[--ip]);
      state2 = table.initialState(weights[--ip]);
      state1 = table.encode(writer, state1, weights[--ip]);
      writer.flush();
    } else {
      state2 = table.initialState(weights[--ip]);
      state1 = table.initialState(weights[--ip]);
    }
    if ((size - 2) & 2 != 0) {
      state2 = table.encode(writer, state2, weights[--ip]);
      state1 = table.encode(writer, state1, weights[--ip]);
      writer.flush();
    }
    while (ip > 0) {
      state2 = table.encode(writer, state2, weights[--ip]);
      state1 = table.encode(writer, state1, weights[--ip]);
      state2 = table.encode(writer, state2, weights[--ip]);
      state1 = table.encode(writer, state1, weights[--ip]);
      writer.flush();
    }
    writer.add(state2, log);
    writer.flush();
    writer.add(state1, log);
    writer.flush();
    return writer.close() - at;
  }

  /// Encodes `src[start...end]` at [at] and returns the bytes it took, or -1
  /// when a stream would not fit in the sixteen bits the jump table has
  /// Set while the decoder holds a tree from a dictionary, which makes a short
  /// section one stream whatever its size
  bool oneStream = false;

  int encodeLiterals(Uint8List out, int at, Uint8List src, int start, int end) {
    final size = end - start;
    if (size < zstdFourStreamsFrom || oneStream) {
      return _encodeOne(out, at, src, start, end);
    }
    final segment = (size + 3) >> 2;
    var write = at + 6;
    for (var i = 0; i < 4; i++) {
      final from = start + i * segment;
      final to = i == 3 ? end : from + segment;
      final took = _encodeOne(out, write, src, from, to);
      if (took <= 0 || (i < 3 && took > 65535)) {
        return -1;
      }
      if (i < 3) {
        out[at + i * 2] = took & 0xff;
        out[at + i * 2 + 1] = (took >> 8) & 0xff;
      }
      write += took;
    }
    return write - at;
  }

  /// Symbols go in from the last to the first, so the reader, which reads the
  /// bytes backwards, gets them in order
  int _encodeOne(Uint8List out, int at, Uint8List src, int start, int end) {
    if (!zstdUse64Bit) {
      final writer = ZstdBitWriter(ByteData.sublistView(out), at);
      var n = end;
      while (n > start) {
        for (var group = 0; group < 4 && n > start; group++) {
          final e = _elt[src[--n]];
          writer.addClean(e & 0xffff, e >> 16);
        }
        writer.flush();
      }
      return writer.close() - at;
    }
    // The counts below are masked so the shifts compile without a range guard
    final view = ByteData.sublistView(out);
    final elt = _elt;
    var held = 0;
    var bits = 0;
    var write = at;
    var n = end;

    var odd = (end - start) & 3;
    while (odd-- > 0) {
      final e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
    }
    view.setUint64(write, held, Endian.little);
    write += bits >> 3;
    held >>>= bits & 56;
    bits &= 7;

    if ((n - start) & 7 != 0) {
      var e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      view.setUint64(write, held, Endian.little);
      write += bits >> 3;
      held >>>= bits & 56;
      bits &= 7;
    }

    // Eight symbols a pass. The second four fill a container of their own so
    // that their chain of dependent shifts does not wait on the first four's
    // flush, `HUF_zeroIndex1` and `HUF_mergeIndex1`. Unrolled by hand because
    // AOT leaves a loop this short rolled, which measured ten milliseconds
    while (n > start) {
      var e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      e = elt[src[--n]];
      held |= (e & 0xffff) << (bits & 63);
      bits += e >> 16;
      view.setUint64(write, held, Endian.little);
      write += bits >> 3;
      held >>>= bits & 56;
      bits &= 7;

      var spare = 0;
      var spareBits = 0;
      var f = elt[src[--n]];
      spare |= (f & 0xffff) << (spareBits & 63);
      spareBits += f >> 16;
      f = elt[src[--n]];
      spare |= (f & 0xffff) << (spareBits & 63);
      spareBits += f >> 16;
      f = elt[src[--n]];
      spare |= (f & 0xffff) << (spareBits & 63);
      spareBits += f >> 16;
      f = elt[src[--n]];
      spare |= (f & 0xffff) << (spareBits & 63);
      spareBits += f >> 16;
      held |= spare << (bits & 63);
      bits += spareBits;
      view.setUint64(write, held, Endian.little);
      write += bits >> 3;
      held >>>= bits & 56;
      bits &= 7;
    }

    held |= 1 << (bits & 63);
    bits++;
    view.setUint64(write, held, Endian.little);
    write += bits >> 3;
    return write + ((bits & 7) > 0 ? 1 : 0) - at;
  }
}

import 'dart:typed_data';

import 'zstd_constants.dart';
import 'zstd_huffman.dart';

/// Threshold that keeps `consumed + tableLog` inside 64 bits, since the longest
/// code is 11
const _reloadAt = 48;

/// Decodes [count] literals from one stream into `dst[dstStart...]`
void decodeHuffmanStream(ZstdHuffmanTable table, Uint8List src, int start,
    int length, Uint8List dst, int dstStart, int count) {
  if (count == 0) {
    checkEmptyHuffmanStream(src, start, length);
    return;
  }
  if (length < 8) {
    decodeHuffmanStreamSlow(table, src, start, length, dst, dstStart, count);
    return;
  }

  final view = ByteData.sublistView(src);
  final rows = table.rows;
  final shift = 63 - table.tableLog;
  final last = src[start + length - 1];
  if (last == 0) {
    _zeroByte();
  }

  var position = start + length - 8;
  var container = view.getUint64(position, Endian.little);
  var consumed = 8 - zstdHighestBit(last);
  var out = dstStart;

  // Two fixed shifts: a variable `>>>` is a compare and a branch
  for (var i = 0; i < count; i++) {
    final row = rows[(container << consumed) >>> 1 >>> shift];
    dst[out++] = row;
    consumed += row >> 8;
    if (consumed > _reloadAt) {
      final step = consumed >> 3;
      if (position - step < start) {
        consumed -= (position - start) << 3;
        position = start;
        if (consumed > 64) {
          _streamShort();
        }
      } else {
        position -= step;
        consumed &= 7;
      }
      container = view.getUint64(position, Endian.little);
    }
  }
  if (position != start || consumed != 64) {
    _lengthMismatch();
  }
}

/// Decodes four streams at once, the way the format shapes them. The chains are
/// independent and keep the pipeline fed
void decodeHuffman4Streams(
    ZstdHuffmanTable table,
    Uint8List src,
    Uint32List starts,
    Uint32List lengths,
    Uint8List dst,
    int dstStart,
    int total,
    int segment) {
  final tail = total - 3 * segment;
  if (tail < 0 || tail > segment) {
    _splitMismatch();
  }
  for (var s = 0; s < 4; s++) {
    if (lengths[s] < 8) {
      for (var t = 0; t < 4; t++) {
        decodeHuffmanStreamSlow(table, src, starts[t], lengths[t], dst,
            dstStart + t * segment, t == 3 ? tail : segment);
      }
      return;
    }
  }

  final view = ByteData.sublistView(src);
  final rows = table.rows;
  final shift = 63 - table.tableLog;

  final s0 = starts[0], s1 = starts[1], s2 = starts[2], s3 = starts[3];
  var p0 = s0 + lengths[0] - 8;
  var p1 = s1 + lengths[1] - 8;
  var p2 = s2 + lengths[2] - 8;
  var p3 = s3 + lengths[3] - 8;
  var n0 = _firstBit(src, s0, lengths[0]);
  var n1 = _firstBit(src, s1, lengths[1]);
  var n2 = _firstBit(src, s2, lengths[2]);
  var n3 = _firstBit(src, s3, lengths[3]);
  var c0 = view.getUint64(p0, Endian.little);
  var c1 = view.getUint64(p1, Endian.little);
  var c2 = view.getUint64(p2, Endian.little);
  var c3 = view.getUint64(p3, Endian.little);

  var o0 = dstStart;
  var o1 = dstStart + segment;
  var o2 = dstStart + 2 * segment;
  var o3 = dstStart + 3 * segment;

  // Four symbols a step, written out rather than nested in a loop: AOT leaves a
  // `for (var u = 0; u < 4; u++)` rolled, and `>>> 1 >>> shift` is two fixed
  // shifts where `>>> (63 - x)` would be a compare and a branch
  final grouped = tail - (tail & 3);
  for (var i = 0; i < grouped; i += 4) {
    {
      final r0 = rows[(c0 << n0) >>> 1 >>> shift];
      final r1 = rows[(c1 << n1) >>> 1 >>> shift];
      final r2 = rows[(c2 << n2) >>> 1 >>> shift];
      final r3 = rows[(c3 << n3) >>> 1 >>> shift];
      dst[o0++] = r0;
      dst[o1++] = r1;
      dst[o2++] = r2;
      dst[o3++] = r3;
      n0 += r0 >> 8;
      n1 += r1 >> 8;
      n2 += r2 >> 8;
      n3 += r3 >> 8;
    }
    {
      final r0 = rows[(c0 << n0) >>> 1 >>> shift];
      final r1 = rows[(c1 << n1) >>> 1 >>> shift];
      final r2 = rows[(c2 << n2) >>> 1 >>> shift];
      final r3 = rows[(c3 << n3) >>> 1 >>> shift];
      dst[o0++] = r0;
      dst[o1++] = r1;
      dst[o2++] = r2;
      dst[o3++] = r3;
      n0 += r0 >> 8;
      n1 += r1 >> 8;
      n2 += r2 >> 8;
      n3 += r3 >> 8;
    }
    {
      final r0 = rows[(c0 << n0) >>> 1 >>> shift];
      final r1 = rows[(c1 << n1) >>> 1 >>> shift];
      final r2 = rows[(c2 << n2) >>> 1 >>> shift];
      final r3 = rows[(c3 << n3) >>> 1 >>> shift];
      dst[o0++] = r0;
      dst[o1++] = r1;
      dst[o2++] = r2;
      dst[o3++] = r3;
      n0 += r0 >> 8;
      n1 += r1 >> 8;
      n2 += r2 >> 8;
      n3 += r3 >> 8;
    }
    {
      final r0 = rows[(c0 << n0) >>> 1 >>> shift];
      final r1 = rows[(c1 << n1) >>> 1 >>> shift];
      final r2 = rows[(c2 << n2) >>> 1 >>> shift];
      final r3 = rows[(c3 << n3) >>> 1 >>> shift];
      dst[o0++] = r0;
      dst[o1++] = r1;
      dst[o2++] = r2;
      dst[o3++] = r3;
      n0 += r0 >> 8;
      n1 += r1 >> 8;
      n2 += r2 >> 8;
      n3 += r3 >> 8;
    }
    {
      {
        final step = n0 >> 3;
        if (p0 - step < s0) {
          n0 -= (p0 - s0) << 3;
          p0 = s0;
        } else {
          p0 -= step;
          n0 &= 7;
        }
        c0 = view.getUint64(p0, Endian.little);
      }
      {
        final step = n1 >> 3;
        if (p1 - step < s1) {
          n1 -= (p1 - s1) << 3;
          p1 = s1;
        } else {
          p1 -= step;
          n1 &= 7;
        }
        c1 = view.getUint64(p1, Endian.little);
      }
      {
        final step = n2 >> 3;
        if (p2 - step < s2) {
          n2 -= (p2 - s2) << 3;
          p2 = s2;
        } else {
          p2 -= step;
          n2 &= 7;
        }
        c2 = view.getUint64(p2, Endian.little);
      }
      {
        final step = n3 >> 3;
        if (p3 - step < s3) {
          n3 -= (p3 - s3) << 3;
          p3 = s3;
        } else {
          p3 -= step;
          n3 &= 7;
        }
        c3 = view.getUint64(p3, Endian.little);
      }
      if (n0 > 64 || n1 > 64 || n2 > 64 || n3 > 64) {
        _oneStreamShort();
      }
    }
  }
  for (var i = grouped; i < tail; i++) {
    final r0 = rows[(c0 << n0) >>> 1 >>> shift];
    final r1 = rows[(c1 << n1) >>> 1 >>> shift];
    final r2 = rows[(c2 << n2) >>> 1 >>> shift];
    final r3 = rows[(c3 << n3) >>> 1 >>> shift];
    dst[o0++] = r0;
    dst[o1++] = r1;
    dst[o2++] = r2;
    dst[o3++] = r3;
    n0 += r0 >> 8;
    n1 += r1 >> 8;
    n2 += r2 >> 8;
    n3 += r3 >> 8;
  }
  {
    final step = n0 >> 3;
    if (p0 - step < s0) {
      n0 -= (p0 - s0) << 3;
      p0 = s0;
    } else {
      p0 -= step;
      n0 &= 7;
    }
    c0 = view.getUint64(p0, Endian.little);
  }
  {
    final step = n1 >> 3;
    if (p1 - step < s1) {
      n1 -= (p1 - s1) << 3;
      p1 = s1;
    } else {
      p1 -= step;
      n1 &= 7;
    }
    c1 = view.getUint64(p1, Endian.little);
  }
  {
    final step = n2 >> 3;
    if (p2 - step < s2) {
      n2 -= (p2 - s2) << 3;
      p2 = s2;
    } else {
      p2 -= step;
      n2 &= 7;
    }
    c2 = view.getUint64(p2, Endian.little);
  }
  {
    final step = n3 >> 3;
    if (p3 - step < s3) {
      n3 -= (p3 - s3) << 3;
      p3 = s3;
    } else {
      p3 -= step;
      n3 &= 7;
    }
    c3 = view.getUint64(p3, Endian.little);
  }

  // The fourth stream is the short one, the other three still owe a symbol each
  for (var i = tail; i < segment; i++) {
    final r0 = rows[(c0 << n0) >>> 1 >>> shift];
    final r1 = rows[(c1 << n1) >>> 1 >>> shift];
    final r2 = rows[(c2 << n2) >>> 1 >>> shift];
    dst[o0++] = r0;
    dst[o1++] = r1;
    dst[o2++] = r2;
    n0 += r0 >> 8;
    n1 += r1 >> 8;
    n2 += r2 >> 8;
    if (i & 3 == 3) {
      {
        final step = n0 >> 3;
        if (p0 - step < s0) {
          n0 -= (p0 - s0) << 3;
          p0 = s0;
        } else {
          p0 -= step;
          n0 &= 7;
        }
        c0 = view.getUint64(p0, Endian.little);
      }
      {
        final step = n1 >> 3;
        if (p1 - step < s1) {
          n1 -= (p1 - s1) << 3;
          p1 = s1;
        } else {
          p1 -= step;
          n1 &= 7;
        }
        c1 = view.getUint64(p1, Endian.little);
      }
      {
        final step = n2 >> 3;
        if (p2 - step < s2) {
          n2 -= (p2 - s2) << 3;
          p2 = s2;
        } else {
          p2 -= step;
          n2 &= 7;
        }
        c2 = view.getUint64(p2, Endian.little);
      }
      if (n0 > 64 || n1 > 64 || n2 > 64) {
        _oneStreamShort();
      }
    }
  }
  {
    final step = n0 >> 3;
    if (p0 - step < s0) {
      n0 -= (p0 - s0) << 3;
      p0 = s0;
    } else {
      p0 -= step;
      n0 &= 7;
    }
    c0 = view.getUint64(p0, Endian.little);
  }
  {
    final step = n1 >> 3;
    if (p1 - step < s1) {
      n1 -= (p1 - s1) << 3;
      p1 = s1;
    } else {
      p1 -= step;
      n1 &= 7;
    }
    c1 = view.getUint64(p1, Endian.little);
  }
  {
    final step = n2 >> 3;
    if (p2 - step < s2) {
      n2 -= (p2 - s2) << 3;
      p2 = s2;
    } else {
      p2 -= step;
      n2 &= 7;
    }
    c2 = view.getUint64(p2, Endian.little);
  }

  if (p0 != s0 ||
      p1 != s1 ||
      p2 != s2 ||
      p3 != s3 ||
      n0 != 64 ||
      n1 != 64 ||
      n2 != 64 ||
      n3 != 64) {
    _notConsumed();
  }
}

int _firstBit(Uint8List src, int start, int length) {
  final last = src[start + length - 1];
  if (last == 0) {
    _zeroByte();
  }
  return 8 - zstdHighestBit(last);
}

/// Every throw of the literal loops is moved out of line. Left inline, the
/// exception's construction puts an allocation and a call in a function that is
/// otherwise all register work, and it costs registers on the path that never
/// throws
@pragma('vm:never-inline')
Never _zeroByte() => throw ZstdHuffmanException('Stream ends in a zero byte');

@pragma('vm:never-inline')
Never _streamShort() =>
    throw ZstdHuffmanException('Stream is shorter than its literals');

@pragma('vm:never-inline')
Never _lengthMismatch() =>
    throw ZstdHuffmanException('Stream length does not match its literals');

@pragma('vm:never-inline')
Never _splitMismatch() =>
    throw ZstdHuffmanException('Stream split does not add up');

@pragma('vm:never-inline')
Never _oneStreamShort() =>
    throw ZstdHuffmanException('A stream is shorter than its literals');

@pragma('vm:never-inline')
Never _notConsumed() =>
    throw ZstdHuffmanException('A stream was not consumed to its end');

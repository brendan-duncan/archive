import 'dart:typed_data';

// XXH64 for backends where an int is a real 64 bit integer, whose arithmetic
// wraps exactly as the algorithm needs. See xxhash64.dart.

const int _p1 = 0x9E3779B185EBCA87;
const int _p2 = 0xC2B2AE3D27D4EB4F;
const int _p3 = 0x165667B19E3779F9;
const int _p4 = 0x85EBCA77C2B2AE63;
const int _p5 = 0x27D4EB2F165667C5;

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _rotl(int x, int r) => (x << r) | (x >>> (64 - r));

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _round(int acc, int input) => _rotl(acc + input * _p2, 31) * _p1;

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _merge(int h, int v) => (h ^ _round(0, v)) * _p1 + _p4;

/// Computes XXH64 with a seed of zero, as zstd's content checksum uses.
class XxHash64 {
  int _v1 = _p1 + _p2;
  int _v2 = _p2;
  int _v3 = 0;
  int _v4 = -_p1;
  int _total = 0;
  final Uint8List _mem = Uint8List(32);
  late final ByteData _memData = ByteData.sublistView(_mem);
  int _memSize = 0;

  void reset() {
    _v1 = _p1 + _p2;
    _v2 = _p2;
    _v3 = 0;
    _v4 = -_p1;
    _total = 0;
    _memSize = 0;
  }

  /// Adds the bytes of [data] from [start] to [end].
  void update(Uint8List data, int start, int end) {
    final len = end - start;
    _total += len;
    if (_memSize + len < 32) {
      _mem.setRange(_memSize, _memSize + len, data, start);
      _memSize += len;
      return;
    }
    if (_memSize > 0) {
      final fill = 32 - _memSize;
      _mem.setRange(_memSize, 32, data, start);
      start += fill;
      _stripes(_memData, 0, 32);
      _memSize = 0;
    }
    final stripesEnd = end - ((end - start) & 31);
    if (stripesEnd > start) {
      _stripes(ByteData.sublistView(data), start, stripesEnd);
    }
    _mem.setRange(0, end - stripesEnd, data, stripesEnd);
    _memSize = end - stripesEnd;
  }

  void _stripes(ByteData d, int start, int end) {
    var v1 = _v1;
    var v2 = _v2;
    var v3 = _v3;
    var v4 = _v4;
    for (var i = start; i < end; i += 32) {
      v1 = _round(v1, d.getUint64(i, Endian.little));
      v2 = _round(v2, d.getUint64(i + 8, Endian.little));
      v3 = _round(v3, d.getUint64(i + 16, Endian.little));
      v4 = _round(v4, d.getUint64(i + 24, Endian.little));
    }
    _v1 = v1;
    _v2 = v2;
    _v3 = v3;
    _v4 = v4;
  }

  /// The low 32 bits of the hash of everything added so far.
  int digestLow32() {
    int h;
    if (_total >= 32) {
      h = _rotl(_v1, 1) + _rotl(_v2, 7) + _rotl(_v3, 12) + _rotl(_v4, 18);
      h = _merge(h, _v1);
      h = _merge(h, _v2);
      h = _merge(h, _v3);
      h = _merge(h, _v4);
    } else {
      h = _p5;
    }
    h += _total;

    final d = _memData;
    var i = 0;
    for (; i + 8 <= _memSize; i += 8) {
      h ^= _round(0, d.getUint64(i, Endian.little));
      h = _rotl(h, 27) * _p1 + _p4;
    }
    if (i + 4 <= _memSize) {
      h ^= d.getUint32(i, Endian.little) * _p1;
      h = _rotl(h, 23) * _p2 + _p3;
      i += 4;
    }
    for (; i < _memSize; i++) {
      h ^= _mem[i] * _p5;
      h = _rotl(h, 11) * _p1;
    }

    h ^= h >>> 33;
    h *= _p2;
    h ^= h >>> 29;
    h *= _p3;
    h ^= h >>> 32;
    return h & 0xffffffff;
  }
}

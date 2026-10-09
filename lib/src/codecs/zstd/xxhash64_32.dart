import 'dart:typed_data';

// XXH64 for JavaScript targets, where an int cannot hold 64 bits. Every value
// is carried as a high and a low 32 bit half, and the arithmetic is done in
// pieces small enough to stay exact in a double. See xxhash64.dart.
//
// Nothing here depends on JavaScript's truncating bitwise operators, so this
// gives the same results on the VM, where it is tested against the 64 bit
// implementation.

const int _m = 0xffffffff;
const int _p1h = 0x9E3779B1, _p1l = 0x85EBCA87;
const int _p2h = 0xC2B2AE3D, _p2l = 0x27D4EB4F;
const int _p3h = 0x165667B1, _p3l = 0x9E3779F9;
const int _p4h = 0x85EBCA77, _p4l = 0xC2B2AE63;
const int _p5h = 0x27D4EB2F, _p5l = 0x165667C5;

// The result of the last 64 bit operation, high half then low. A typed list
// rather than two variables because JavaScript engines store a number this
// large in a variable or a field as a separate allocation, and in a typed list
// as it is.
final Uint32List _r = Uint32List(2);

// The primes split into 16 bit limbs, lowest first, for multiplying by.
const int _p1a = 0xCA87, _p1b = 0x85EB, _p1c = 0x79B1, _p1d = 0x9E37;
const int _p2a = 0xEB4F, _p2b = 0x27D4, _p2c = 0xAE3D, _p2d = 0xC2B2;
const int _p3a = 0x79F9, _p3b = 0x9E37, _p3c = 0x67B1, _p3d = 0x1656;
const int _p5a = 0x67C5, _p5b = 0x1656, _p5c = 0xEB2F, _p5d = 0x27D4;

// (ah:al) * (d:c:b:a), modulo 2^64, where a to d are 16 bit limbs. Every
// product of a 32 bit half and a limb is below 2^48 and so exact in a double,
// and the terms that land at or above 2^64 are never formed.
void _mul(int ah, int al, int a, int b, int c, int d) {
  final t = al * b;
  final lo = al * a + (t & 0xffff) * 0x10000;
  _r[1] = lo & _m;
  _r[0] = (lo ~/ 0x100000000 +
          t ~/ 0x10000 +
          al * c +
          ((al * d) & 0xffff) * 0x10000 +
          ah * a +
          ((ah * b) & 0xffff) * 0x10000) &
      _m;
}

// (ah:al) + (bh:bl), modulo 2^64.
void _add(int ah, int al, int bh, int bl) {
  var lo = al + bl;
  var carry = 0;
  if (lo > _m) {
    lo -= 0x100000000;
    carry = 1;
  }
  _r[0] = (ah + bh + carry) & _m;
  _r[1] = lo;
}

// (h:l) rotated left by r, which is between 1 and 31.
void _rotl(int h, int l, int r) {
  _r[0] = ((h << r) | (l >>> (32 - r))) & _m;
  _r[1] = ((l << r) | (h >>> (32 - r))) & _m;
}

// rotl(acc + input * p2, 31) * p1
void _round(int ah, int al, int ih, int il) {
  _mul(ih, il, _p2a, _p2b, _p2c, _p2d);
  _add(ah, al, _r[0], _r[1]);
  _rotl(_r[0], _r[1], 31);
  _mul(_r[0], _r[1], _p1a, _p1b, _p1c, _p1d);
}

/// Computes XXH64 with a seed of zero, as zstd's content checksum uses.
class XxHash64 {
  // The four lanes, each high half then low, in a typed list for the same
  // reason as _r.
  final Uint32List _v = Uint32List(8);
  int _total = 0;
  final Uint8List _mem = Uint8List(32);
  int _memSize = 0;

  XxHash64() {
    reset();
  }

  void reset() {
    _add(_p1h, _p1l, _p2h, _p2l);
    _v[0] = _r[0];
    _v[1] = _r[1];
    _v[2] = _p2h;
    _v[3] = _p2l;
    _v[4] = 0;
    _v[5] = 0;
    // 0 - p1
    _v[6] = 0x61C8864E;
    _v[7] = 0x7A143579;
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
      _stripes(_mem, 0, 32);
      _memSize = 0;
    }
    final stripesEnd = end - ((end - start) & 31);
    if (stripesEnd > start) {
      _stripes(data, start, stripesEnd);
    }
    _mem.setRange(0, end - stripesEnd, data, stripesEnd);
    _memSize = end - stripesEnd;
  }

  static int _read32(Uint8List d, int i) =>
      d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] * 0x1000000);

  void _stripes(Uint8List d, int start, int end) {
    for (var i = start; i < end; i += 32) {
      _round(_v[0], _v[1], _read32(d, i + 4), _read32(d, i));
      _v[0] = _r[0];
      _v[1] = _r[1];
      _round(_v[2], _v[3], _read32(d, i + 12), _read32(d, i + 8));
      _v[2] = _r[0];
      _v[3] = _r[1];
      _round(_v[4], _v[5], _read32(d, i + 20), _read32(d, i + 16));
      _v[4] = _r[0];
      _v[5] = _r[1];
      _round(_v[6], _v[7], _read32(d, i + 28), _read32(d, i + 24));
      _v[6] = _r[0];
      _v[7] = _r[1];
    }
  }

  // h = (h ^ round(0, v)) * p1 + p4
  static void _merge(int hh, int hl, int vh, int vl) {
    _round(0, 0, vh, vl);
    _mul(hh ^ _r[0], hl ^ _r[1], _p1a, _p1b, _p1c, _p1d);
    _add(_r[0], _r[1], _p4h, _p4l);
  }

  /// The low 32 bits of the hash of everything added so far.
  int digestLow32() {
    int hh, hl;
    if (_total >= 32) {
      _rotl(_v[0], _v[1], 1);
      hh = _r[0];
      hl = _r[1];
      _rotl(_v[2], _v[3], 7);
      _add(hh, hl, _r[0], _r[1]);
      hh = _r[0];
      hl = _r[1];
      _rotl(_v[4], _v[5], 12);
      _add(hh, hl, _r[0], _r[1]);
      hh = _r[0];
      hl = _r[1];
      _rotl(_v[6], _v[7], 18);
      _add(hh, hl, _r[0], _r[1]);
      _merge(_r[0], _r[1], _v[0], _v[1]);
      _merge(_r[0], _r[1], _v[2], _v[3]);
      _merge(_r[0], _r[1], _v[4], _v[5]);
      _merge(_r[0], _r[1], _v[6], _v[7]);
      hh = _r[0];
      hl = _r[1];
    } else {
      hh = _p5h;
      hl = _p5l;
    }
    // The total as a 64 bit value, exact up to 2^53 bytes.
    _add(hh, hl, _total ~/ 0x100000000, _total % 0x100000000);
    hh = _r[0];
    hl = _r[1];

    final d = _mem;
    var i = 0;
    for (; i + 8 <= _memSize; i += 8) {
      _round(0, 0, _read32(d, i + 4), _read32(d, i));
      _rotl(hh ^ _r[0], hl ^ _r[1], 27);
      _mul(_r[0], _r[1], _p1a, _p1b, _p1c, _p1d);
      _add(_r[0], _r[1], _p4h, _p4l);
      hh = _r[0];
      hl = _r[1];
    }
    if (i + 4 <= _memSize) {
      _mul(0, _read32(d, i), _p1a, _p1b, _p1c, _p1d);
      _rotl(hh ^ _r[0], hl ^ _r[1], 23);
      _mul(_r[0], _r[1], _p2a, _p2b, _p2c, _p2d);
      _add(_r[0], _r[1], _p3h, _p3l);
      hh = _r[0];
      hl = _r[1];
      i += 4;
    }
    for (; i < _memSize; i++) {
      _mul(0, d[i], _p5a, _p5b, _p5c, _p5d);
      _rotl(hh ^ _r[0], hl ^ _r[1], 11);
      _mul(_r[0], _r[1], _p1a, _p1b, _p1c, _p1d);
      hh = _r[0];
      hl = _r[1];
    }

    // Avalanche
    hl ^= hh >>> 1;
    _mul(hh, hl, _p2a, _p2b, _p2c, _p2d);
    hh = _r[0];
    hl = _r[1];
    hl ^= ((hl >>> 29) | (hh << 3)) & _m;
    hh ^= hh >>> 29;
    _mul(hh, hl, _p3a, _p3b, _p3c, _p3d);
    hh = _r[0];
    hl = _r[1];
    return (hl ^ hh) & _m;
  }
}

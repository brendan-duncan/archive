import 'dart:typed_data';

const _p1Hi = 0x9e3779b1, _p1Lo = 0x85ebca87;
const _p2Hi = 0xc2b2ae3d, _p2Lo = 0x27d4eb4f;
const _p3Hi = 0x165667b1, _p3Lo = 0x9e3779f9;
const _p4Hi = 0x85ebca77, _p4Lo = 0xc2b2ae63;
const _p5Hi = 0x27d4eb2f, _p5Lo = 0x165667c5;

/// One 64 bit value as two unsigned 32 bit halves, mutated in place so the
/// rounds allocate nothing
class _U64 {
  int hi;
  int lo;

  _U64(this.hi, this.lo);

  void set(int h, int l) {
    hi = h;
    lo = l;
  }

  void add(int bhi, int blo) {
    final l = lo + blo;
    lo = l >>> 0;
    hi = (hi + bhi + (l >= 4294967296 ? 1 : 0)) >>> 0;
  }

  void sub(int bhi, int blo) {
    final l = lo - blo;
    lo = l >>> 0;
    hi = (hi - bhi - (l < 0 ? 1 : 0)) >>> 0;
  }

  void xor(int bhi, int blo) {
    hi ^= bhi;
    lo ^= blo;
  }

  void mul(int bhi, int blo) {
    final a0 = lo & 0xffff, a1 = lo >>> 16;
    final b0 = blo & 0xffff, b1 = blo >>> 16;
    final p00 = a0 * b0;
    final p01 = a0 * b1;
    final p10 = a1 * b0;
    final mid = (p00 >>> 16) + (p01 & 0xffff) + (p10 & 0xffff);
    final carry = (mid >>> 16) + (p01 >>> 16) + (p10 >>> 16) + a1 * b1;
    hi = (carry + _mul32(hi, blo) + _mul32(lo, bhi)) >>> 0;
    lo = ((p00 & 0xffff) | ((mid & 0xffff) << 16)) >>> 0;
  }

  /// [count] in 1 to 31
  void rotl(int count) {
    final back = 32 - count;
    final h = ((hi << count) | (lo >>> back)) >>> 0;
    lo = ((lo << count) | (hi >>> back)) >>> 0;
    hi = h;
  }

  void shr(int count) {
    if (count >= 32) {
      lo = hi >>> (count - 32);
      hi = 0;
      return;
    }
    lo = ((lo >>> count) | (hi << (32 - count))) >>> 0;
    hi = hi >>> count;
  }
}

/// Low 32 bits of a 32 by 32 bit product
int _mul32(int a, int b) =>
    (((a & 0xffff) * (b & 0xffff)) +
        ((((a >>> 16) * (b & 0xffff) + (a & 0xffff) * (b >>> 16)) << 16) >>>
            0)) >>>
    0;

/// The seed is taken as a 64 bit value split into two 32 bit halves
class Xxh64 {
  final int _seedHi;
  final int _seedLo;
  final _U64 _v1 = _U64(0, 0);
  final _U64 _v2 = _U64(0, 0);
  final _U64 _v3 = _U64(0, 0);
  final _U64 _v4 = _U64(0, 0);
  final _U64 _scratch = _U64(0, 0);
  int _total = 0;
  int _held = 0;

  final Uint8List _buffer = Uint8List(32);
  late final ByteData _bufferView = ByteData.sublistView(_buffer);

  Xxh64([int seed = 0])
      : _seedLo = seed & 0xffffffff,
        _seedHi = ((seed - (seed & 0xffffffff)) ~/ 0x100000000) & 0xffffffff {
    reset();
  }

  void reset() {
    _v1.set(_seedHi, _seedLo);
    _v1.add(_p1Hi, _p1Lo);
    _v1.add(_p2Hi, _p2Lo);
    _v2.set(_seedHi, _seedLo);
    _v2.add(_p2Hi, _p2Lo);
    _v3.set(_seedHi, _seedLo);
    _v4.set(_seedHi, _seedLo);
    _v4.sub(_p1Hi, _p1Lo);
    _total = 0;
    _held = 0;
  }

  void update(Uint8List data, int start, int length) {
    if (length <= 0) {
      return;
    }
    _total += length;
    var at = start;
    var left = length;

    if (_held > 0) {
      final need = 32 - _held;
      if (left < need) {
        _buffer.setRange(_held, _held + left, data, at);
        _held += left;
        return;
      }
      _buffer.setRange(_held, 32, data, at);
      _absorb(_bufferView, 0, 1);
      _held = 0;
      at += need;
      left -= need;
    }

    final blocks = left >> 5;
    if (blocks > 0) {
      _absorb(ByteData.sublistView(data), at, blocks);
      at += blocks << 5;
      left -= blocks << 5;
    }
    if (left > 0) {
      _buffer.setRange(0, left, data, at);
      _held = left;
    }
  }

  int get digestHigh => _digest().hi;

  int get digestLow => _digest().lo;

  _U64 _digest() {
    final h = _U64(0, 0);
    if (_total >= 32) {
      _scratch.set(_v1.hi, _v1.lo);
      _scratch.rotl(1);
      h.set(_scratch.hi, _scratch.lo);
      _addRotated(h, _v2, 7);
      _addRotated(h, _v3, 12);
      _addRotated(h, _v4, 18);
      _merge(h, _v1);
      _merge(h, _v2);
      _merge(h, _v3);
      _merge(h, _v4);
    } else {
      h.set(_seedHi, _seedLo);
      h.add(_p5Hi, _p5Lo);
    }
    h.add(_total ~/ 4294967296, _total % 4294967296);

    var at = 0;
    var left = _held;
    while (left >= 8) {
      _scratch.set(0, 0);
      _round(_scratch, _bufferView.getUint32(at + 4, Endian.little),
          _bufferView.getUint32(at, Endian.little));
      h.xor(_scratch.hi, _scratch.lo);
      h.rotl(27);
      h.mul(_p1Hi, _p1Lo);
      h.add(_p4Hi, _p4Lo);
      at += 8;
      left -= 8;
    }
    if (left >= 4) {
      _scratch.set(0, _bufferView.getUint32(at, Endian.little));
      _scratch.mul(_p1Hi, _p1Lo);
      h.xor(_scratch.hi, _scratch.lo);
      h.rotl(23);
      h.mul(_p2Hi, _p2Lo);
      h.add(_p3Hi, _p3Lo);
      at += 4;
      left -= 4;
    }
    while (left > 0) {
      _scratch.set(0, _buffer[at]);
      _scratch.mul(_p5Hi, _p5Lo);
      h.xor(_scratch.hi, _scratch.lo);
      h.rotl(11);
      h.mul(_p1Hi, _p1Lo);
      at++;
      left--;
    }

    _avalanche(h);
    return h;
  }

  void _absorb(ByteData view, int offset, int blocks) {
    var at = offset;
    for (var i = 0; i < blocks; i++) {
      _round(_v1, view.getUint32(at + 4, Endian.little),
          view.getUint32(at, Endian.little));
      _round(_v2, view.getUint32(at + 12, Endian.little),
          view.getUint32(at + 8, Endian.little));
      _round(_v3, view.getUint32(at + 20, Endian.little),
          view.getUint32(at + 16, Endian.little));
      _round(_v4, view.getUint32(at + 28, Endian.little),
          view.getUint32(at + 24, Endian.little));
      at += 32;
    }
  }

  static final _U64 _tmp = _U64(0, 0);

  static void _round(_U64 acc, int inputHi, int inputLo) {
    _tmp.set(inputHi, inputLo);
    _tmp.mul(_p2Hi, _p2Lo);
    acc.add(_tmp.hi, _tmp.lo);
    acc.rotl(31);
    acc.mul(_p1Hi, _p1Lo);
  }

  void _addRotated(_U64 h, _U64 value, int count) {
    _scratch.set(value.hi, value.lo);
    _scratch.rotl(count);
    h.add(_scratch.hi, _scratch.lo);
  }

  void _merge(_U64 h, _U64 value) {
    _scratch.set(0, 0);
    _round(_scratch, value.hi, value.lo);
    h.xor(_scratch.hi, _scratch.lo);
    h.mul(_p1Hi, _p1Lo);
    h.add(_p4Hi, _p4Lo);
  }

  static void _avalanche(_U64 h) {
    _tmp.set(h.hi, h.lo);
    _tmp.shr(33);
    h.xor(_tmp.hi, _tmp.lo);
    h.mul(_p2Hi, _p2Lo);
    _tmp.set(h.hi, h.lo);
    _tmp.shr(29);
    h.xor(_tmp.hi, _tmp.lo);
    h.mul(_p3Hi, _p3Lo);
    _tmp.set(h.hi, h.lo);
    _tmp.shr(32);
    h.xor(_tmp.hi, _tmp.lo);
  }
}

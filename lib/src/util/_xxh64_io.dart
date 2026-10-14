import 'dart:typed_data';

const _prime1 = 0x9e3779b185ebca87;
const _prime2 = 0xc2b2ae3d27d4eb4f;
const _prime3 = 0x165667b19e3779f9;
const _prime4 = 0x85ebca77c2b2ae63;
const _prime5 = 0x27d4eb2f165667c5;

class Xxh64 {
  final int _seed;
  int _v1;
  int _v2;
  int _v3;
  int _v4;
  int _total = 0;
  int _held = 0;

  final Uint8List _buffer = Uint8List(32);
  late final ByteData _bufferView = ByteData.sublistView(_buffer);

  Xxh64([int seed = 0])
      : _seed = seed,
        _v1 = seed + _prime1 + _prime2,
        _v2 = seed + _prime2,
        _v3 = seed,
        _v4 = seed - _prime1;

  void reset() {
    _v1 = _seed + _prime1 + _prime2;
    _v2 = _seed + _prime2;
    _v3 = _seed;
    _v4 = _seed - _prime1;
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

  int get digestHigh => _digest() >>> 32;

  int get digestLow => _digest() & 0xffffffff;

  int _digest() {
    int h;
    if (_total >= 32) {
      h = _rotl(_v1, 1) + _rotl(_v2, 7) + _rotl(_v3, 12) + _rotl(_v4, 18);
      h = _merge(h, _v1);
      h = _merge(h, _v2);
      h = _merge(h, _v3);
      h = _merge(h, _v4);
    } else {
      h = _seed + _prime5;
    }
    h += _total;

    var at = 0;
    var left = _held;
    while (left >= 8) {
      h ^= _round(0, _bufferView.getUint64(at, Endian.little));
      h = _rotl(h, 27) * _prime1 + _prime4;
      at += 8;
      left -= 8;
    }
    if (left >= 4) {
      h ^= _bufferView.getUint32(at, Endian.little) * _prime1;
      h = _rotl(h, 23) * _prime2 + _prime3;
      at += 4;
      left -= 4;
    }
    while (left > 0) {
      h ^= _buffer[at] * _prime5;
      h = _rotl(h, 11) * _prime1;
      at++;
      left--;
    }

    h ^= h >>> 33;
    h *= _prime2;
    h ^= h >>> 29;
    h *= _prime3;
    h ^= h >>> 32;
    return h;
  }

  void _absorb(ByteData view, int offset, int blocks) {
    var v1 = _v1;
    var v2 = _v2;
    var v3 = _v3;
    var v4 = _v4;
    var at = offset;
    for (var i = 0; i < blocks; i++) {
      v1 = _round(v1, view.getUint64(at, Endian.little));
      v2 = _round(v2, view.getUint64(at + 8, Endian.little));
      v3 = _round(v3, view.getUint64(at + 16, Endian.little));
      v4 = _round(v4, view.getUint64(at + 24, Endian.little));
      at += 32;
    }
    _v1 = v1;
    _v2 = v2;
    _v3 = v3;
    _v4 = v4;
  }

  @pragma('vm:prefer-inline')
  static int _rotl(int value, int count) =>
      (value << count) | (value >>> (64 - count));

  @pragma('vm:prefer-inline')
  static int _round(int acc, int input) {
    var v = acc + input * _prime2;
    v = _rotl(v, 31);
    return v * _prime1;
  }

  static int _merge(int acc, int value) =>
      (acc ^ _round(0, value)) * _prime1 + _prime4;
}

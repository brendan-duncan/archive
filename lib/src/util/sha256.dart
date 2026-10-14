import 'dart:typed_data';

const _k1 = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

// A mask here makes the VM convert each round input to uint32 again, 9%
// slower on AOT, so bits above 32 stay until a sum is masked or stored
// Should become better if accepted and fixed:
// https://github.com/dart-lang/sdk/issues/64389
int _rotr(int x, int n) => (x >>> n) | (x << (32 - n));

// TODO: right now speed is 200MB/s, however it can be improved up to ~380MB/s
// if loops are unrolled. However it requires ~1700 lines of code instead of for
// loops. Readability hardly matters here since such encryption classes do not
// change and work without issues from day 0.
class Sha256 {
  final _state = Uint32List(8);
  final _w = Uint32List(64);
  final _tail = Uint8List(64);
  var _tailLength = 0;
  var _total = 0;

  Sha256() {
    reset();
  }

  static Uint8List of(Uint8List data) =>
      (Sha256()..update(data, 0, data.length)).digest();

  void reset() {
    _state.setAll(0, const [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]);
    _tailLength = 0;
    _total = 0;
  }

  void update(Uint8List data, int start, int length) {
    if (length <= 0) {
      return;
    }
    _total += length;
    var at = start;
    final end = start + length;
    if (_tailLength > 0) {
      final take = length < 64 - _tailLength ? length : 64 - _tailLength;
      _tail.setRange(_tailLength, _tailLength + take, data, at);
      _tailLength += take;
      at += take;
      if (_tailLength < 64) {
        return;
      }
      _compress(_tail, 0, 64);
      _tailLength = 0;
    }
    final whole = at + ((end - at) & ~63);
    _compress(data, at, whole);
    _tail.setRange(0, end - whole, data, whole);
    _tailLength = end - whole;
  }

  Uint8List digest() {
    final padded = Uint8List(_tailLength < 56 ? 64 : 128)
      ..setRange(0, _tailLength, _tail);
    padded[_tailLength] = 0x80;
    // A shift by 32 or more is masked to 5 bits on dart2js, so the bit count
    // is split with ~/ to stay exact up to 2^53
    var bits = _total * 8;
    for (var i = padded.length - 1; i >= padded.length - 8; i--) {
      padded[i] = bits % 256;
      bits ~/= 256;
    }
    _compress(padded, 0, padded.length);
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final v = _state[i];
      out[4 * i] = v >>> 24;
      out[4 * i + 1] = (v >>> 16) & 0xff;
      out[4 * i + 2] = (v >>> 8) & 0xff;
      out[4 * i + 3] = v & 0xff;
    }
    reset();
    return out;
  }

  void _compress(Uint8List d, int at, int end) {
    final h = _state;
    final w = _w;
    for (; at < end; at += 64) {
      for (var i = 0; i < 16; i++) {
        final o = at + 4 * i;
        w[i] = (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
      }
      for (var i = 16; i < 64; i++) {
        final x = w[i - 15], y = w[i - 2];
        final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
        final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
      }
      var a = h[0], b = h[1], c = h[2], dd = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = g ^ (e & (f ^ g));
        final t1 = (hh + s1 + ch + _k1[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & (b | c)) | (b & c);
        hh = g;
        g = f;
        f = e;
        e = (dd + t1) & 0xffffffff;
        dd = c;
        c = b;
        b = a;
        a = (t1 + s0 + maj) & 0xffffffff;
      }
      h[0] += a;
      h[1] += b;
      h[2] += c;
      h[3] += dd;
      h[4] += e;
      h[5] += f;
      h[6] += g;
      h[7] += hh;
    }
  }
}

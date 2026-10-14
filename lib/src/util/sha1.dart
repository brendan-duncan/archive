import 'dart:typed_data';

// The result keeps bits above 32. A rotated word that is stored or rotated
// again is masked, the rest only reaches sums that are masked, as in
// sha256.dart
int _rotl(int x, int n) => (x << n) | (x >>> (32 - n));

class Sha1 {
  final _state = Uint32List(5);
  final _w = Uint32List(80);
  final _tail = Uint8List(64);
  var _tailLength = 0;
  var _total = 0;

  Sha1() {
    reset();
  }

  void reset() {
    _state.setAll(0, const [
      0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0, //
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

  /// Writes the 20-byte digest to [out] at [offset] and resets
  void finish(Uint8List out, int offset) {
    final tail = _tail;
    var length = _tailLength;
    tail[length++] = 0x80;
    if (length > 56) {
      tail.fillRange(length, 64, 0);
      _compress(tail, 0, 64);
      length = 0;
    }
    tail.fillRange(length, 56, 0);
    // A shift by 32 or more is masked to 5 bits on dart2js, so the bit count
    // is split with ~/ to stay exact up to 2^53
    var bits = _total * 8;
    for (var i = 63; i >= 56; i--) {
      tail[i] = bits % 256;
      bits ~/= 256;
    }
    _compress(tail, 0, 64);
    for (var i = 0; i < 5; i++) {
      final v = _state[i];
      out[offset + 4 * i] = v >>> 24;
      out[offset + 4 * i + 1] = (v >>> 16) & 0xff;
      out[offset + 4 * i + 2] = (v >>> 8) & 0xff;
      out[offset + 4 * i + 3] = v & 0xff;
    }
    reset();
  }

  Uint8List digest() {
    final out = Uint8List(20);
    finish(out, 0);
    return out;
  }

  void _save(Uint32List to) => to.setAll(0, _state);

  /// Resumes from a state saved by [_save] after one whole block
  void _resume(Uint32List from) {
    _state.setAll(0, from);
    _tailLength = 0;
    _total = 64;
  }

  void _compress(Uint8List d, int at, int end) {
    final w = _w;
    for (; at < end; at += 64) {
      for (var i = 0; i < 16; i++) {
        final o = at + 4 * i;
        w[i] = (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
      }
      _compressBlock();
    }
  }

  /// Compresses the block already in the first 16 words of [_w]
  @pragma('vm:prefer-inline')
  void _compressBlock() {
    final h = _state;
    final w = _w;
    {
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h[0], b = h[1], c = h[2], dd = h[3], e = h[4];
      // Dart adds left to right, so the term with a goes last to keep the
      // other adds off the chain between rounds. Five rounds a pass rename a..e
      // in place instead of moving them: 0.26 to 0.17 us a block on M4
      for (var i = 0; i < 20; i += 5) {
        e = (e + 0x5a827999 + w[i] + (dd ^ (b & (c ^ dd))) + _rotl(a, 5)) &
            0xffffffff;
        b = _rotl(b, 30) & 0xffffffff;
        dd = (dd + 0x5a827999 + w[i + 1] + (c ^ (a & (b ^ c))) + _rotl(e, 5)) &
            0xffffffff;
        a = _rotl(a, 30) & 0xffffffff;
        c = (c + 0x5a827999 + w[i + 2] + (b ^ (e & (a ^ b))) + _rotl(dd, 5)) &
            0xffffffff;
        e = _rotl(e, 30) & 0xffffffff;
        b = (b + 0x5a827999 + w[i + 3] + (a ^ (dd & (e ^ a))) + _rotl(c, 5)) &
            0xffffffff;
        dd = _rotl(dd, 30) & 0xffffffff;
        a = (a + 0x5a827999 + w[i + 4] + (e ^ (c & (dd ^ e))) + _rotl(b, 5)) &
            0xffffffff;
        c = _rotl(c, 30) & 0xffffffff;
      }
      for (var i = 20; i < 40; i += 5) {
        e = (e + 0x6ed9eba1 + w[i] + (b ^ c ^ dd) + _rotl(a, 5)) & 0xffffffff;
        b = _rotl(b, 30) & 0xffffffff;
        dd = (dd + 0x6ed9eba1 + w[i + 1] + (a ^ b ^ c) + _rotl(e, 5)) &
            0xffffffff;
        a = _rotl(a, 30) & 0xffffffff;
        c = (c + 0x6ed9eba1 + w[i + 2] + (e ^ a ^ b) + _rotl(dd, 5)) &
            0xffffffff;
        e = _rotl(e, 30) & 0xffffffff;
        b = (b + 0x6ed9eba1 + w[i + 3] + (dd ^ e ^ a) + _rotl(c, 5)) &
            0xffffffff;
        dd = _rotl(dd, 30) & 0xffffffff;
        a = (a + 0x6ed9eba1 + w[i + 4] + (c ^ dd ^ e) + _rotl(b, 5)) &
            0xffffffff;
        c = _rotl(c, 30) & 0xffffffff;
      }
      for (var i = 40; i < 60; i += 5) {
        e = (e + 0x8f1bbcdc + w[i] + ((b & c) | (dd & (b | c))) + _rotl(a, 5)) &
            0xffffffff;
        b = _rotl(b, 30) & 0xffffffff;
        dd = (dd +
                0x8f1bbcdc +
                w[i + 1] +
                ((a & b) | (c & (a | b))) +
                _rotl(e, 5)) &
            0xffffffff;
        a = _rotl(a, 30) & 0xffffffff;
        c = (c +
                0x8f1bbcdc +
                w[i + 2] +
                ((e & a) | (b & (e | a))) +
                _rotl(dd, 5)) &
            0xffffffff;
        e = _rotl(e, 30) & 0xffffffff;
        b = (b +
                0x8f1bbcdc +
                w[i + 3] +
                ((dd & e) | (a & (dd | e))) +
                _rotl(c, 5)) &
            0xffffffff;
        dd = _rotl(dd, 30) & 0xffffffff;
        a = (a +
                0x8f1bbcdc +
                w[i + 4] +
                ((c & dd) | (e & (c | dd))) +
                _rotl(b, 5)) &
            0xffffffff;
        c = _rotl(c, 30) & 0xffffffff;
      }
      for (var i = 60; i < 80; i += 5) {
        e = (e + 0xca62c1d6 + w[i] + (b ^ c ^ dd) + _rotl(a, 5)) & 0xffffffff;
        b = _rotl(b, 30) & 0xffffffff;
        dd = (dd + 0xca62c1d6 + w[i + 1] + (a ^ b ^ c) + _rotl(e, 5)) &
            0xffffffff;
        a = _rotl(a, 30) & 0xffffffff;
        c = (c + 0xca62c1d6 + w[i + 2] + (e ^ a ^ b) + _rotl(dd, 5)) &
            0xffffffff;
        e = _rotl(e, 30) & 0xffffffff;
        b = (b + 0xca62c1d6 + w[i + 3] + (dd ^ e ^ a) + _rotl(c, 5)) &
            0xffffffff;
        dd = _rotl(dd, 30) & 0xffffffff;
        a = (a + 0xca62c1d6 + w[i + 4] + (c ^ dd ^ e) + _rotl(b, 5)) &
            0xffffffff;
        c = _rotl(c, 30) & 0xffffffff;
      }
      h[0] += a;
      h[1] += b;
      h[2] += c;
      h[3] += dd;
      h[4] += e;
    }
  }
}

/// HMAC-SHA1
class HmacSha1 {
  static const macSize = 20;

  final _digest = Sha1();
  final _inner = Uint32List(5);
  final _outer = Uint32List(5);
  final _hash = Uint8List(20);

  HmacSha1(Uint8List key) {
    final block = Uint8List(64);
    if (key.length > 64) {
      _digest
        ..update(key, 0, key.length)
        ..finish(block, 0);
    } else {
      block.setRange(0, key.length, key);
    }
    // The padded key is one whole block, so the state after it is saved once
    // instead of hashing the block again for every message, which doubled
    // the cost of PBKDF2
    for (var i = 0; i < 64; i++) {
      block[i] ^= 0x36;
    }
    _digest
      ..update(block, 0, 64)
      .._save(_inner);
    for (var i = 0; i < 64; i++) {
      block[i] ^= 0x36 ^ 0x5c;
    }
    _digest
      ..reset()
      ..update(block, 0, 64)
      .._save(_outer)
      .._resume(_inner);
  }

  void update(Uint8List data, int start, int length) =>
      _digest.update(data, start, length);

  /// Writes the 20-byte MAC to [out] at [offset] and starts a new message
  void finish(Uint8List out, int offset) {
    _digest
      ..finish(_hash, 0)
      .._resume(_outer)
      ..update(_hash, 0, 20)
      ..finish(out, offset)
      .._resume(_inner);
  }
}

/// PBKDF2-HMAC-SHA1, [length] bytes of key from [password]
Uint8List pbkdf2HmacSha1(
    Uint8List password, Uint8List salt, int iterations, int length) {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be positive');
  }
  final mac = HmacSha1(password);
  final sha = mac._digest;
  final w = sha._w;
  final h = sha._state;
  final pads = [mac._inner, mac._outer];
  final out = Uint8List(length);
  final index = Uint8List(4);
  final first = Uint8List(20);
  final u = Uint32List(5);
  final t = Uint32List(5);
  for (var block = 1, at = 0; at < length; block++, at += 20) {
    index[0] = block >>> 24;
    index[1] = (block >>> 16) & 0xff;
    index[2] = (block >>> 8) & 0xff;
    index[3] = block & 0xff;
    mac
      ..update(salt, 0, salt.length)
      ..update(index, 0, 4)
      ..finish(first, 0);
    for (var j = 0; j < 5; j++) {
      final o = 4 * j;
      u[j] = (first[o] << 24) |
          (first[o + 1] << 16) |
          (first[o + 2] << 8) |
          first[o + 3];
      t[j] = u[j];
    }
    // Each later message is the 20-byte MAC before it, so both hashes of an
    // iteration are one block of words with 84 bytes as the length. Skipping
    // update and finish took PBKDF2 from 1.71 to 1.32 ms on M4
    for (var i = 1; i < iterations; i++) {
      for (final pad in pads) {
        w.setAll(0, u);
        w[5] = 0x80000000;
        w.fillRange(6, 15, 0);
        w[15] = 84 * 8;
        h.setAll(0, pad);
        sha._compressBlock();
        u.setAll(0, h);
      }
      for (var j = 0; j < 5; j++) {
        t[j] ^= u[j];
      }
    }
    sha._resume(mac._inner);
    for (var j = 0; j < 20 && at + j < length; j++) {
      out[at + j] = (t[j >>> 2] >>> (24 - 8 * (j & 3))) & 0xff;
    }
  }
  return out;
}

import 'dart:typed_data';

// This code is copied from the PointyCastle library,
// https://github.com/PointyCastle/pointycastle.
// See LICENSE-other.md for license info.

abstract class CipherParameters {}

class Pbkdf2Parameters extends CipherParameters {
  final Uint8List salt;
  final int iterationCount;
  final int desiredKeyLength;

  Pbkdf2Parameters(this.salt, this.iterationCount, this.desiredKeyLength);
}

abstract class KeyDerivator {
  int get keySize;
  void init(CipherParameters params);
  Uint8List process(Uint8List data);
  int deriveKey(Uint8List inp, int inpOff, Uint8List out, int outOff);
}

abstract class BaseKeyDerivator implements KeyDerivator {
  @override
  Uint8List process(Uint8List data) {
    var out = Uint8List(keySize);
    var len = deriveKey(data, 0, out, 0);
    return out.sublist(0, len);
  }
}

void arrayCopy(Uint8List? sourceArr, int sourcePos, Uint8List? outArr,
    int outPos, int len) {
  for (var i = 0; i < len; i++) {
    outArr![outPos + i] = sourceArr![sourcePos + i];
  }
}

abstract class Mac {
  int get macSize;

  void reset();
  void init(CipherParameters params);
  Uint8List process(Uint8List data);
  void updateByte(int inp);
  void update(Uint8List inp, int inpOff, int len);
  int doFinal(Uint8List out, int outOff);
}

class KeyParameter extends CipherParameters {
  late Uint8List key;
  KeyParameter(this.key);
  KeyParameter.offset(Uint8List key, int keyOff, int keyLen) {
    this.key = Uint8List(keyLen);
    arrayCopy(key, keyOff, this.key, 0, keyLen);
  }
}

class PBKDF2KeyDerivator extends BaseKeyDerivator {
  late Pbkdf2Parameters _params;
  final Mac _mac;
  late Uint8List _state;

  PBKDF2KeyDerivator(this._mac) {
    _state = Uint8List(_mac.macSize);
  }

  @override
  int get keySize => _params.desiredKeyLength;

  void reset() {
    _mac.reset();
    _state.fillRange(0, _state.length, 0);
  }

  @override
  void init(covariant Pbkdf2Parameters params) {
    _params = params;
  }

  @override
  int deriveKey(Uint8List inp, int inpOff, Uint8List out, int outOff) {
    var dkLen = _params.desiredKeyLength;
    var hLen = _mac.macSize;
    var l = (dkLen + hLen - 1) ~/ hLen;
    var iBuf = Uint8List(4);
    var outBytes = Uint8List(l * hLen);
    var outPos = 0;

    CipherParameters param = KeyParameter(inp.sublist(inpOff));
    _mac.init(param);

    for (var i = 1; i <= l; i++) {
      for (var pos = 3;; pos--) {
        iBuf[pos]++;
        if (iBuf[pos] != 0) break;
      }

      _f(_params.salt, _params.iterationCount, iBuf, outBytes, outPos);
      outPos += hLen;
    }

    out.setRange(outOff, outOff + dkLen, outBytes);

    return keySize;
  }

  void _f(Uint8List? S, int c, Uint8List iBuf, Uint8List out, int outOff) {
    if (c <= 0) {
      throw ArgumentError('Iteration count must be at least 1.');
    }

    if (S != null) {
      _mac.update(S, 0, S.length);
    }

    _mac.update(iBuf, 0, iBuf.length);
    _mac.doFinal(_state, 0);

    out.setRange(outOff, outOff + _state.length, _state);

    for (var count = 1; count < c; count++) {
      _mac.update(_state, 0, _state.length);
      _mac.doFinal(_state, 0);

      for (var j = 0; j != _state.length; j++) {
        out[outOff + j] ^= _state[j];
      }
    }
  }
}

abstract class BaseMac implements Mac {
  @override
  Uint8List process(Uint8List data) {
    update(data, 0, data.length);
    var out = Uint8List(macSize);
    var len = doFinal(out, 0);
    return out.sublist(0, len);
  }
}

abstract class BaseDigest implements Digest {
  @override
  Uint8List process(Uint8List data) {
    update(data, 0, data.length);
    var out = Uint8List(digestSize);
    var len = doFinal(out, 0);
    return out.sublist(0, len);
  }
}

const _mask5 = 0x1F;
const _mask6 = 0x3F;
const _mask8 = 0xFF;
const _mask16 = 0xFFFF;
const _mask32 = 0xFFFFFFFF;

final _mask32HiBits = [
  0xFFFFFFFF,
  0x7FFFFFFF,
  0x3FFFFFFF,
  0x1FFFFFFF,
  0x0FFFFFFF,
  0x07FFFFFF,
  0x03FFFFFF,
  0x01FFFFFF,
  0x00FFFFFF,
  0x007FFFFF,
  0x003FFFFF,
  0x001FFFFF,
  0x000FFFFF,
  0x0007FFFF,
  0x0003FFFF,
  0x0001FFFF,
  0x0000FFFF,
  0x00007FFF,
  0x00003FFF,
  0x00001FFF,
  0x00000FFF,
  0x000007FF,
  0x000003FF,
  0x000001FF,
  0x000000FF,
  0x0000007F,
  0x0000003F,
  0x0000001F,
  0x0000000F,
  0x00000007,
  0x00000003,
  0x00000001,
  0x00000000
];

int shiftl32(int x, int n) {
  assert((x >= 0) && (x <= _mask32));
  n &= _mask5;
  x &= _mask32HiBits[n];
  return (x << n) & _mask32;
}

int shiftr32(int x, int n) {
  assert((x >= 0) && (x <= _mask32));
  n &= _mask5;
  return x >> n;
}

int clip8(int x) => x & _mask8;

int clip32(int x) => x & _mask32;

void pack32(int x, ByteData out, int offset, Endian endian) {
  assert((x >= 0) && (x <= _mask32));
  out.setUint32(offset, x, endian);
}

ByteData byteDataView(Uint8List inp) =>
    ByteData.view(inp.buffer, inp.offsetInBytes, inp.length);

int unpack32(ByteData inp, int offset, Endian endian) {
  return inp.getUint32(offset, endian);
}

int rotl32(int x, int n) {
  assert(n >= 0);
  assert((x >= 0) && (x <= _mask32));
  n &= _mask5;
  return shiftl32(x, n) | (x >> (32 - n));
}

int rotr32(int x, int n) {
  assert(n >= 0);
  assert((x >= 0) && (x <= _mask32));
  n &= _mask5;
  return (x >> n) | shiftl32(x, 32 - n);
}

class Register64 {
  late int _hi32;
  late int _lo32;

  Register64([Object hiOrLo32OrY = 0, int? lo32]) {
    if (hiOrLo32OrY is int) {
      setInt(hiOrLo32OrY, lo32);
    } else {
      set(hiOrLo32OrY as Register64, lo32);
    }
  }

  int get lo32 => _lo32;
  int get hi32 => _hi32;

  @override
  bool operator ==(Object other) => other is Register64
      ? (((_hi32 == other._hi32) && (_lo32 == other._lo32)))
      : false;
  bool operator <(Register64 y) =>
      (_hi32 < y._hi32) || ((_hi32 == y._hi32) && (_lo32 < y._lo32));
  bool operator <=(Register64 y) => (this < y) || (this == y);
  bool operator >(Register64 y) =>
      (_hi32 > y._hi32) || ((_hi32 == y._hi32) && (_lo32 > y._lo32));
  bool operator >=(Register64 y) => (this > y) || (this == y);

  void setInt(int hiOrLo32OrY, [int? lo32]) {
    if (lo32 == null) {
      assert(hiOrLo32OrY <= _mask32);
      _hi32 = 0;
      _lo32 = hiOrLo32OrY;
    } else {
      assert(hiOrLo32OrY <= _mask32);
      assert(lo32 <= _mask32);
      _hi32 = hiOrLo32OrY;
      _lo32 = lo32;
    }
  }

  void set(Register64 hiOrLo32OrY, [int? lo32]) {
    if (lo32 == null) {
      _hi32 = hiOrLo32OrY._hi32;
      _lo32 = hiOrLo32OrY._lo32;
    }
  }

  void sum(int y) {
    y &= _mask32;
    var slo32 = _lo32 + y;
    _lo32 = slo32 & _mask32;
    if (slo32 != _lo32) {
      _hi32++;
      _hi32 &= _mask32;
    }
  }

  void sumReg(Register64 y) {
    var slo32 = _lo32 + y._lo32;
    _lo32 = slo32 & _mask32;
    var carry = ((slo32 != _lo32) ? 1 : 0);
    _hi32 = (_hi32 + y._hi32 + carry) & _mask32;
  }

  void mul(int y) {
    final a0 = _lo32 & _mask16;
    final a1 = (_lo32 >> 16) & _mask16;
    final a2 = _hi32 & _mask16;
    final a3 = (_hi32 >> 16) & _mask16;
    late int b0, b1, b2, b3;
    y &= _mask32;
    b0 = y & _mask16;
    b1 = (y >> 16) & _mask16;
    b2 = b3 = 0;

    var p0 = a0 * b0;
    var p1 = a1 * b0;
    var p2 = a2 * b0;
    var p3 = a3 * b0;

    if (b1 != 0) {
      p1 += a0 * b1;
      p2 += a1 * b1;
      p3 += a2 * b1;
    }
    if (b2 != 0) {
      p2 += a0 * b2;
      p3 += a1 * b2;
    }
    if (b3 != 0) {
      p3 += a0 * b3;
    }

    var slo32 = p0 + ((p1 & _mask16) << 16);
    _lo32 = slo32 & _mask32;
    var carry = ((slo32 != _lo32) ? 1 : 0);
    var carry2 = ((p1 & _mask32) != p1) ? 0x10000 : 0;
    var shi32 =
        ((p1 & _mask32) >> 16) + p2 + ((p3 & _mask16) << 16) + carry + carry2;
    _hi32 = shi32 & _mask32;
  }

  void and(Register64 y) {
    _hi32 &= y._hi32;
    _lo32 &= y._lo32;
  }

  void or(Register64 y) {
    _hi32 |= y._hi32;
    _lo32 |= y._lo32;
  }

  void xor(Register64 y) {
    _hi32 ^= y._hi32;
    _lo32 ^= y._lo32;
  }

  void shiftl(int n) {
    n &= _mask6;
    if (n == 0) {
      // do nothing
    } else if (n >= 32) {
      _hi32 = shiftl32(_lo32, n - 32);
      _lo32 = 0;
    } else {
      _hi32 = shiftl32(_hi32, n);
      _hi32 |= _lo32 >> (32 - n);
      _lo32 = shiftl32(_lo32, n);
    }
  }

  void shiftr(int n) {
    n &= _mask6;
    if (n == 0) {
      // do nothing
    } else if (n >= 32) {
      _lo32 = _hi32 >> (n - 32);
      _hi32 = 0;
    } else {
      _lo32 = _lo32 >> n;
      _lo32 |= shiftl32(_hi32, 32 - n);
      _hi32 = _hi32 >> n;
    }
  }

  void rotl(int n) {
    n &= _mask6;
    if (n == 0) {
      // do nothing
    } else {
      if (n >= 32) {
        var swap = _hi32;
        _hi32 = _lo32;
        _lo32 = swap;
        n -= 32;
      }
      if (n == 0) {
        // do nothing
      } else {
        var hi32 = _hi32;
        _hi32 = shiftl32(_hi32, n);
        _hi32 |= _lo32 >> (32 - n);
        _lo32 = shiftl32(_lo32, n);
        _lo32 |= hi32 >> (32 - n);
      }
    }
  }

  void rotr(int n) {
    n &= _mask6;
    if (n == 0) {
      // do nothing
    } else {
      if (n >= 32) {
        var swap = _hi32;
        _hi32 = _lo32;
        _lo32 = swap;
        n -= 32;
      }
      if (n == 0) {
        // do nothing
      } else {
        var hi32 = _hi32;
        _hi32 = _hi32 >> n;
        _hi32 |= shiftl32(_lo32, 32 - n);
        _lo32 = _lo32 >> n;
        _lo32 |= shiftl32(hi32, 32 - n);
      }
    }
  }

  void mod(int n) {
    if (_hi32 == 0) {
      _lo32 %= n;
    } else {
      const b = 0x10000;
      final a0 = _lo32 & _mask16;
      final a1 = (_lo32 >> 16) & _mask16;
      final a2 = _hi32 & _mask16;
      final a3 = (_hi32 >> 16) & _mask16;
      _lo32 = ((((((a3 % n) * b + a2) % n) * b + a1) % n) * b + a0) % n;
      _hi32 = 0;
    }
  }

  void pack(ByteData out, int offset, Endian endian) {
    switch (endian) {
      case Endian.big:
        pack32(hi32, out, offset, endian);
        pack32(lo32, out, offset + 4, endian);
        break;

      case Endian.little:
        pack32(hi32, out, offset + 4, endian);
        pack32(lo32, out, offset, endian);
        break;

      default:
        throw UnsupportedError('Invalid endianness: $endian');
    }
  }

  void unpack(ByteData inp, int offset, Endian endian) {
    switch (endian) {
      case Endian.big:
        _hi32 = unpack32(inp, offset, endian);
        _lo32 = unpack32(inp, offset + 4, endian);
        break;

      case Endian.little:
        _hi32 = unpack32(inp, offset + 4, endian);
        _lo32 = unpack32(inp, offset, endian);
        break;

      default:
        throw UnsupportedError('Invalid endianness: $endian');
    }
  }

  @override
  String toString() {
    var sb = StringBuffer();
    _padWrite(sb, _hi32);
    _padWrite(sb, _lo32);
    return sb.toString();
  }

  void _padWrite(StringBuffer sb, int value) {
    var str = value.toRadixString(16);
    for (var i = 8 - str.length; i > 0; i--) {
      sb.write('0');
    }
    sb.write(str);
  }

  @override
  int get hashCode => Object.hash(_hi32, _lo32);
}

abstract class MD4FamilyDigest extends BaseDigest {
  final _byteCount = Register64(0);

  final _wordBuffer = Uint8List(4);
  late int _wordBufferOffset;

  final Endian _endian;
  final int _packedStateSize;

  final List<int> state;

  final List<int> buffer;
  late int bufferOffset;

  MD4FamilyDigest(this._endian, int stateSize, int bufferSize,
      [int? packedStateSize])
      : _packedStateSize =
            (packedStateSize == null) ? stateSize : packedStateSize,
        state = List<int>.filled(stateSize, 0, growable: false),
        buffer = List<int>.filled(bufferSize, 0, growable: false) {
    reset();
  }

  void resetState();

  void processBlock();

  @override
  void reset() {
    _byteCount.setInt(0);

    _wordBufferOffset = 0;
    _wordBuffer.fillRange(0, _wordBuffer.length, 0);

    bufferOffset = 0;
    buffer.fillRange(0, buffer.length, 0);

    resetState();
  }

  @override
  void updateByte(int inp) {
    _wordBuffer[_wordBufferOffset++] = clip8(inp);
    _processWordIfBufferFull();
    _byteCount.sum(1);
  }

  @override
  void update(Uint8List inp, int inpOff, int len) {
    int nbytes = _processUntilNextWord(inp, inpOff, len);
    inpOff += nbytes;
    len -= nbytes;
    nbytes = _processWholeWords(inp, inpOff, len);
    inpOff += nbytes;
    len -= nbytes;
    _processBytes(inp, inpOff, len);
  }

  @override
  int doFinal(Uint8List out, int outOff) {
    var bitLength = Register64(_byteCount)..shiftl(3);

    _processPadding();
    _processLength(bitLength);
    _doProcessBlock();

    _packState(out, outOff);

    reset();

    return digestSize;
  }

  void _processWord(Uint8List inp, int inpOff) {
    buffer[bufferOffset++] = unpack32(
        ByteData.view(inp.buffer, inp.offsetInBytes, inp.length),
        inpOff,
        _endian);

    if (bufferOffset == 16) {
      _doProcessBlock();
    }
  }

  void _doProcessBlock() {
    processBlock();

    bufferOffset = 0;
    buffer.fillRange(0, 16, 0);
  }

  void _processBytes(Uint8List inp, int inpOff, int len) {
    while (len > 0) {
      updateByte(inp[inpOff]);

      inpOff++;
      len--;
    }
  }

  int _processWholeWords(Uint8List inp, int inpOff, int len) {
    var processed = 0;
    while (len > _wordBuffer.length) {
      _processWord(inp, inpOff);

      inpOff += _wordBuffer.length;
      len -= _wordBuffer.length;
      _byteCount.sum(_wordBuffer.length);
      processed += 4;
    }
    return processed;
  }

  int _processUntilNextWord(Uint8List inp, int inpOff, int len) {
    var processed = 0;

    while ((_wordBufferOffset != 0) && (len > 0)) {
      updateByte(inp[inpOff]);

      inpOff++;
      len--;
      processed++;
    }

    return processed;
  }

  void _processWordIfBufferFull() {
    if (_wordBufferOffset == _wordBuffer.length) {
      _processWord(_wordBuffer, 0);
      _wordBufferOffset = 0;
    }
  }

  void _processPadding() {
    updateByte(128);
    while (_wordBufferOffset != 0) {
      updateByte(0);
    }
  }

  void _processLength(Register64 bitLength) {
    if (bufferOffset > 14) {
      _doProcessBlock();
    }

    switch (_endian) {
      case Endian.little:
        buffer[14] = bitLength.lo32;
        buffer[15] = bitLength.hi32;
        break;

      case Endian.big:
        buffer[14] = bitLength.hi32;
        buffer[15] = bitLength.lo32;
        break;

      default:
        throw StateError('Invalid endianness: $_endian');
    }
  }

  void _packState(Uint8List out, int outOff) {
    for (var i = 0; i < _packedStateSize; i++) {
      pack32(state[i], ByteData.view(out.buffer, out.offsetInBytes, out.length),
          outOff + i * 4, _endian);
    }
  }
}

abstract class Digest {
  int get digestSize;
  int get byteLength;
  void reset();
  Uint8List process(Uint8List data);
  void updateByte(int inp);
  void update(Uint8List inp, int inpOff, int len);
  int doFinal(Uint8List out, int outOff);
}

class SHA1Digest extends MD4FamilyDigest implements Digest {
  static const _digestLength = 20;

  SHA1Digest() : super(Endian.big, 5, 80);

  @override
  final digestSize = _digestLength;

  @override
  void resetState() {
    state[0] = 0x67452301;
    state[1] = 0xefcdab89;
    state[2] = 0x98badcfe;
    state[3] = 0x10325476;
    state[4] = 0xc3d2e1f0;
  }

  @override
  void processBlock() {
    for (var i = 16; i < 80; i++) {
      var t = buffer[i - 3] ^ buffer[i - 8] ^ buffer[i - 14] ^ buffer[i - 16];
      buffer[i] = rotl32(t, 1);
    }

    var A = state[0];
    var B = state[1];
    var C = state[2];
    var D = state[3];
    var E = state[4];

    var idx = 0;

    for (var j = 0; j < 4; j++) {
      E = clip32(E + rotl32(A, 5) + _f(B, C, D) + buffer[idx++] + _Y1);
      B = rotl32(B, 30);

      D = clip32(D + rotl32(E, 5) + _f(A, B, C) + buffer[idx++] + _Y1);
      A = rotl32(A, 30);

      C = clip32(C + rotl32(D, 5) + _f(E, A, B) + buffer[idx++] + _Y1);
      E = rotl32(E, 30);

      B = clip32(B + rotl32(C, 5) + _f(D, E, A) + buffer[idx++] + _Y1);
      D = rotl32(D, 30);

      A = clip32(A + rotl32(B, 5) + _f(C, D, E) + buffer[idx++] + _Y1);
      C = rotl32(C, 30);
    }

    for (var j = 0; j < 4; j++) {
      E = clip32(E + rotl32(A, 5) + _h(B, C, D) + buffer[idx++] + _Y2);
      B = rotl32(B, 30);

      D = clip32(D + rotl32(E, 5) + _h(A, B, C) + buffer[idx++] + _Y2);
      A = rotl32(A, 30);

      C = clip32(C + rotl32(D, 5) + _h(E, A, B) + buffer[idx++] + _Y2);
      E = rotl32(E, 30);

      B = clip32(B + rotl32(C, 5) + _h(D, E, A) + buffer[idx++] + _Y2);
      D = rotl32(D, 30);

      A = clip32(A + rotl32(B, 5) + _h(C, D, E) + buffer[idx++] + _Y2);
      C = rotl32(C, 30);
    }

    for (var j = 0; j < 4; j++) {
      E = clip32(E + rotl32(A, 5) + _g(B, C, D) + buffer[idx++] + _Y3);
      B = rotl32(B, 30);

      D = clip32(D + rotl32(E, 5) + _g(A, B, C) + buffer[idx++] + _Y3);
      A = rotl32(A, 30);

      C = clip32(C + rotl32(D, 5) + _g(E, A, B) + buffer[idx++] + _Y3);
      E = rotl32(E, 30);

      B = clip32(B + rotl32(C, 5) + _g(D, E, A) + buffer[idx++] + _Y3);
      D = rotl32(D, 30);

      A = clip32(A + rotl32(B, 5) + _g(C, D, E) + buffer[idx++] + _Y3);
      C = rotl32(C, 30);
    }

    for (var j = 0; j < 4; j++) {
      E = clip32(E + rotl32(A, 5) + _h(B, C, D) + buffer[idx++] + _Y4);
      B = rotl32(B, 30);

      D = clip32(D + rotl32(E, 5) + _h(A, B, C) + buffer[idx++] + _Y4);
      A = rotl32(A, 30);

      C = clip32(C + rotl32(D, 5) + _h(E, A, B) + buffer[idx++] + _Y4);
      E = rotl32(E, 30);

      B = clip32(B + rotl32(C, 5) + _h(D, E, A) + buffer[idx++] + _Y4);
      D = rotl32(D, 30);

      A = clip32(A + rotl32(B, 5) + _h(C, D, E) + buffer[idx++] + _Y4);
      C = rotl32(C, 30);
    }

    state[0] = clip32(state[0] + A);
    state[1] = clip32(state[1] + B);
    state[2] = clip32(state[2] + C);
    state[3] = clip32(state[3] + D);
    state[4] = clip32(state[4] + E);
  }

  static const _Y1 = 0x5a827999;
  static const _Y2 = 0x6ed9eba1;
  static const _Y3 = 0x8f1bbcdc;
  static const _Y4 = 0xca62c1d6;

  int _f(int u, int v, int w) => (u & v) | ((~u) & w);

  int _h(int u, int v, int w) => u ^ v ^ w;

  int _g(int u, int v, int w) => (u & v) | (u & w) | (v & w);

  @override
  int get byteLength => 64;
}

class HMac extends BaseMac {
  static final _ipad = 0x36;
  static final _opad = 0x5C;

  final Digest _digest;
  late int _digestSize;
  late int _blockLength;

  late Uint8List _inputPad;
  late Uint8List _outputBuf;

  HMac(this._digest, this._blockLength) {
    _digestSize = _digest.digestSize;
    _inputPad = Uint8List(_blockLength);
    _outputBuf = Uint8List(_blockLength + _digestSize);
  }

  HMac.withDigest(this._digest) {
    _blockLength = _digest.byteLength;

    _digestSize = _digest.digestSize;
    _inputPad = Uint8List(_blockLength);
    _outputBuf = Uint8List(_blockLength + _digestSize);
  }

  @override
  int get macSize => _digestSize;

  @override
  void reset() {
    _digest.reset();
    _digest.update(_inputPad, 0, _inputPad.length);
  }

  @override
  void init(covariant KeyParameter params) {
    _digest.reset();

    var key = params.key;
    var keyLength = key.length;

    if (keyLength > _blockLength) {
      _digest.update(key, 0, keyLength);
      _digest.doFinal(_inputPad, 0);

      keyLength = _digestSize;
    } else {
      _inputPad.setRange(0, keyLength, key);
    }

    _inputPad.fillRange(keyLength, _inputPad.length, 0);

    _outputBuf.setRange(0, _blockLength, _inputPad);

    _xorPad(_inputPad, _blockLength, _ipad);
    _xorPad(_outputBuf, _blockLength, _opad);

    _digest.update(_inputPad, 0, _inputPad.length);
  }

  @override
  void updateByte(int inp) {
    _digest.updateByte(inp);
  }

  @override
  void update(Uint8List inp, int inpOff, int len) {
    _digest.update(inp, inpOff, len);
  }

  @override
  int doFinal(Uint8List out, int outOff) {
    _digest.doFinal(_outputBuf, _blockLength);
    _digest.update(_outputBuf, 0, _outputBuf.length);

    var len = _digest.doFinal(out, outOff);
    _outputBuf.fillRange(_blockLength, _outputBuf.length, 0);
    _digest.update(_inputPad, 0, _inputPad.length);

    return len;
  }

  void _xorPad(Uint8List pad, int len, int n) {
    for (var i = 0; i < len; i++) {
      pad[i] ^= n;
    }
  }
}

abstract class BlockCipher {
  int get blockSize;
  void reset();
  void init(bool forEncryption, CipherParameters? params);
  Uint8List process(Uint8List data);
  int processBlock(Uint8List inp, int inpOff, Uint8List out, int outOff);
}

abstract class BaseBlockCipher implements BlockCipher {
  @override
  Uint8List process(Uint8List data) {
    var out = Uint8List(blockSize);
    var len = processBlock(data, 0, out, 0);
    return out.sublist(0, len);
  }
}

class AESEngine extends BaseBlockCipher {
  int _rounds = 0;
  late List<List<int>> _workingKey;
  bool _forEncryption = false;

  List<int> _s = List.empty();

  static const _S = [
    99,
    124,
    119,
    123,
    242,
    107,
    111,
    197,
    48,
    1,
    103,
    43,
    254,
    215,
    171,
    118,
    202,
    130,
    201,
    125,
    250,
    89,
    71,
    240,
    173,
    212,
    162,
    175,
    156,
    164,
    114,
    192,
    183,
    253,
    147,
    38,
    54,
    63,
    247,
    204,
    52,
    165,
    229,
    241,
    113,
    216,
    49,
    21,
    4,
    199,
    35,
    195,
    24,
    150,
    5,
    154,
    7,
    18,
    128,
    226,
    235,
    39,
    178,
    117,
    9,
    131,
    44,
    26,
    27,
    110,
    90,
    160,
    82,
    59,
    214,
    179,
    41,
    227,
    47,
    132,
    83,
    209,
    0,
    237,
    32,
    252,
    177,
    91,
    106,
    203,
    190,
    57,
    74,
    76,
    88,
    207,
    208,
    239,
    170,
    251,
    67,
    77,
    51,
    133,
    69,
    249,
    2,
    127,
    80,
    60,
    159,
    168,
    81,
    163,
    64,
    143,
    146,
    157,
    56,
    245,
    188,
    182,
    218,
    33,
    16,
    255,
    243,
    210,
    205,
    12,
    19,
    236,
    95,
    151,
    68,
    23,
    196,
    167,
    126,
    61,
    100,
    93,
    25,
    115,
    96,
    129,
    79,
    220,
    34,
    42,
    144,
    136,
    70,
    238,
    184,
    20,
    222,
    94,
    11,
    219,
    224,
    50,
    58,
    10,
    73,
    6,
    36,
    92,
    194,
    211,
    172,
    98,
    145,
    149,
    228,
    121,
    231,
    200,
    55,
    109,
    141,
    213,
    78,
    169,
    108,
    86,
    244,
    234,
    101,
    122,
    174,
    8,
    186,
    120,
    37,
    46,
    28,
    166,
    180,
    198,
    232,
    221,
    116,
    31,
    75,
    189,
    139,
    138,
    112,
    62,
    181,
    102,
    72,
    3,
    246,
    14,
    97,
    53,
    87,
    185,
    134,
    193,
    29,
    158,
    225,
    248,
    152,
    17,
    105,
    217,
    142,
    148,
    155,
    30,
    135,
    233,
    206,
    85,
    40,
    223,
    140,
    161,
    137,
    13,
    191,
    230,
    66,
    104,
    65,
    153,
    45,
    15,
    176,
    84,
    187,
    22,
  ];

  static const _Si = [
    82,
    9,
    106,
    213,
    48,
    54,
    165,
    56,
    191,
    64,
    163,
    158,
    129,
    243,
    215,
    251,
    124,
    227,
    57,
    130,
    155,
    47,
    255,
    135,
    52,
    142,
    67,
    68,
    196,
    222,
    233,
    203,
    84,
    123,
    148,
    50,
    166,
    194,
    35,
    61,
    238,
    76,
    149,
    11,
    66,
    250,
    195,
    78,
    8,
    46,
    161,
    102,
    40,
    217,
    36,
    178,
    118,
    91,
    162,
    73,
    109,
    139,
    209,
    37,
    114,
    248,
    246,
    100,
    134,
    104,
    152,
    22,
    212,
    164,
    92,
    204,
    93,
    101,
    182,
    146,
    108,
    112,
    72,
    80,
    253,
    237,
    185,
    218,
    94,
    21,
    70,
    87,
    167,
    141,
    157,
    132,
    144,
    216,
    171,
    0,
    140,
    188,
    211,
    10,
    247,
    228,
    88,
    5,
    184,
    179,
    69,
    6,
    208,
    44,
    30,
    143,
    202,
    63,
    15,
    2,
    193,
    175,
    189,
    3,
    1,
    19,
    138,
    107,
    58,
    145,
    17,
    65,
    79,
    103,
    220,
    234,
    151,
    242,
    207,
    206,
    240,
    180,
    230,
    115,
    150,
    172,
    116,
    34,
    231,
    173,
    53,
    133,
    226,
    249,
    55,
    232,
    28,
    117,
    223,
    110,
    71,
    241,
    26,
    113,
    29,
    41,
    197,
    137,
    111,
    183,
    98,
    14,
    170,
    24,
    190,
    27,
    252,
    86,
    62,
    75,
    198,
    210,
    121,
    32,
    154,
    219,
    192,
    254,
    120,
    205,
    90,
    244,
    31,
    221,
    168,
    51,
    136,
    7,
    199,
    49,
    177,
    18,
    16,
    89,
    39,
    128,
    236,
    95,
    96,
    81,
    127,
    169,
    25,
    181,
    74,
    13,
    45,
    229,
    122,
    159,
    147,
    201,
    156,
    239,
    160,
    224,
    59,
    77,
    174,
    42,
    245,
    176,
    200,
    235,
    187,
    60,
    131,
    83,
    153,
    97,
    23,
    43,
    4,
    126,
    186,
    119,
    214,
    38,
    225,
    105,
    20,
    99,
    85,
    33,
    12,
    125,
  ];

  static const _rcon = [
    0x01,
    0x02,
    0x04,
    0x08,
    0x10,
    0x20,
    0x40,
    0x80,
    0x1b,
    0x36,
    0x6c,
    0xd8,
    0xab,
    0x4d,
    0x9a,
    0x2f,
    0x5e,
    0xbc,
    0x63,
    0xc6,
    0x97,
    0x35,
    0x6a,
    0xd4,
    0xb3,
    0x7d,
    0xfa,
    0xef,
    0xc5,
    0x91
  ];

  static const _T0 = [
    0xa56363c6,
    0x847c7cf8,
    0x997777ee,
    0x8d7b7bf6,
    0x0df2f2ff,
    0xbd6b6bd6,
    0xb16f6fde,
    0x54c5c591,
    0x50303060,
    0x03010102,
    0xa96767ce,
    0x7d2b2b56,
    0x19fefee7,
    0x62d7d7b5,
    0xe6abab4d,
    0x9a7676ec,
    0x45caca8f,
    0x9d82821f,
    0x40c9c989,
    0x877d7dfa,
    0x15fafaef,
    0xeb5959b2,
    0xc947478e,
    0x0bf0f0fb,
    0xecadad41,
    0x67d4d4b3,
    0xfda2a25f,
    0xeaafaf45,
    0xbf9c9c23,
    0xf7a4a453,
    0x967272e4,
    0x5bc0c09b,
    0xc2b7b775,
    0x1cfdfde1,
    0xae93933d,
    0x6a26264c,
    0x5a36366c,
    0x413f3f7e,
    0x02f7f7f5,
    0x4fcccc83,
    0x5c343468,
    0xf4a5a551,
    0x34e5e5d1,
    0x08f1f1f9,
    0x937171e2,
    0x73d8d8ab,
    0x53313162,
    0x3f15152a,
    0x0c040408,
    0x52c7c795,
    0x65232346,
    0x5ec3c39d,
    0x28181830,
    0xa1969637,
    0x0f05050a,
    0xb59a9a2f,
    0x0907070e,
    0x36121224,
    0x9b80801b,
    0x3de2e2df,
    0x26ebebcd,
    0x6927274e,
    0xcdb2b27f,
    0x9f7575ea,
    0x1b090912,
    0x9e83831d,
    0x742c2c58,
    0x2e1a1a34,
    0x2d1b1b36,
    0xb26e6edc,
    0xee5a5ab4,
    0xfba0a05b,
    0xf65252a4,
    0x4d3b3b76,
    0x61d6d6b7,
    0xceb3b37d,
    0x7b292952,
    0x3ee3e3dd,
    0x712f2f5e,
    0x97848413,
    0xf55353a6,
    0x68d1d1b9,
    0x00000000,
    0x2cededc1,
    0x60202040,
    0x1ffcfce3,
    0xc8b1b179,
    0xed5b5bb6,
    0xbe6a6ad4,
    0x46cbcb8d,
    0xd9bebe67,
    0x4b393972,
    0xde4a4a94,
    0xd44c4c98,
    0xe85858b0,
    0x4acfcf85,
    0x6bd0d0bb,
    0x2aefefc5,
    0xe5aaaa4f,
    0x16fbfbed,
    0xc5434386,
    0xd74d4d9a,
    0x55333366,
    0x94858511,
    0xcf45458a,
    0x10f9f9e9,
    0x06020204,
    0x817f7ffe,
    0xf05050a0,
    0x443c3c78,
    0xba9f9f25,
    0xe3a8a84b,
    0xf35151a2,
    0xfea3a35d,
    0xc0404080,
    0x8a8f8f05,
    0xad92923f,
    0xbc9d9d21,
    0x48383870,
    0x04f5f5f1,
    0xdfbcbc63,
    0xc1b6b677,
    0x75dadaaf,
    0x63212142,
    0x30101020,
    0x1affffe5,
    0x0ef3f3fd,
    0x6dd2d2bf,
    0x4ccdcd81,
    0x140c0c18,
    0x35131326,
    0x2fececc3,
    0xe15f5fbe,
    0xa2979735,
    0xcc444488,
    0x3917172e,
    0x57c4c493,
    0xf2a7a755,
    0x827e7efc,
    0x473d3d7a,
    0xac6464c8,
    0xe75d5dba,
    0x2b191932,
    0x957373e6,
    0xa06060c0,
    0x98818119,
    0xd14f4f9e,
    0x7fdcdca3,
    0x66222244,
    0x7e2a2a54,
    0xab90903b,
    0x8388880b,
    0xca46468c,
    0x29eeeec7,
    0xd3b8b86b,
    0x3c141428,
    0x79dedea7,
    0xe25e5ebc,
    0x1d0b0b16,
    0x76dbdbad,
    0x3be0e0db,
    0x56323264,
    0x4e3a3a74,
    0x1e0a0a14,
    0xdb494992,
    0x0a06060c,
    0x6c242448,
    0xe45c5cb8,
    0x5dc2c29f,
    0x6ed3d3bd,
    0xefacac43,
    0xa66262c4,
    0xa8919139,
    0xa4959531,
    0x37e4e4d3,
    0x8b7979f2,
    0x32e7e7d5,
    0x43c8c88b,
    0x5937376e,
    0xb76d6dda,
    0x8c8d8d01,
    0x64d5d5b1,
    0xd24e4e9c,
    0xe0a9a949,
    0xb46c6cd8,
    0xfa5656ac,
    0x07f4f4f3,
    0x25eaeacf,
    0xaf6565ca,
    0x8e7a7af4,
    0xe9aeae47,
    0x18080810,
    0xd5baba6f,
    0x887878f0,
    0x6f25254a,
    0x722e2e5c,
    0x241c1c38,
    0xf1a6a657,
    0xc7b4b473,
    0x51c6c697,
    0x23e8e8cb,
    0x7cdddda1,
    0x9c7474e8,
    0x211f1f3e,
    0xdd4b4b96,
    0xdcbdbd61,
    0x868b8b0d,
    0x858a8a0f,
    0x907070e0,
    0x423e3e7c,
    0xc4b5b571,
    0xaa6666cc,
    0xd8484890,
    0x05030306,
    0x01f6f6f7,
    0x120e0e1c,
    0xa36161c2,
    0x5f35356a,
    0xf95757ae,
    0xd0b9b969,
    0x91868617,
    0x58c1c199,
    0x271d1d3a,
    0xb99e9e27,
    0x38e1e1d9,
    0x13f8f8eb,
    0xb398982b,
    0x33111122,
    0xbb6969d2,
    0x70d9d9a9,
    0x898e8e07,
    0xa7949433,
    0xb69b9b2d,
    0x221e1e3c,
    0x92878715,
    0x20e9e9c9,
    0x49cece87,
    0xff5555aa,
    0x78282850,
    0x7adfdfa5,
    0x8f8c8c03,
    0xf8a1a159,
    0x80898909,
    0x170d0d1a,
    0xdabfbf65,
    0x31e6e6d7,
    0xc6424284,
    0xb86868d0,
    0xc3414182,
    0xb0999929,
    0x772d2d5a,
    0x110f0f1e,
    0xcbb0b07b,
    0xfc5454a8,
    0xd6bbbb6d,
    0x3a16162c
  ];

  static const _Tinv0 = [
    0x50a7f451,
    0x5365417e,
    0xc3a4171a,
    0x965e273a,
    0xcb6bab3b,
    0xf1459d1f,
    0xab58faac,
    0x9303e34b,
    0x55fa3020,
    0xf66d76ad,
    0x9176cc88,
    0x254c02f5,
    0xfcd7e54f,
    0xd7cb2ac5,
    0x80443526,
    0x8fa362b5,
    0x495ab1de,
    0x671bba25,
    0x980eea45,
    0xe1c0fe5d,
    0x02752fc3,
    0x12f04c81,
    0xa397468d,
    0xc6f9d36b,
    0xe75f8f03,
    0x959c9215,
    0xeb7a6dbf,
    0xda595295,
    0x2d83bed4,
    0xd3217458,
    0x2969e049,
    0x44c8c98e,
    0x6a89c275,
    0x78798ef4,
    0x6b3e5899,
    0xdd71b927,
    0xb64fe1be,
    0x17ad88f0,
    0x66ac20c9,
    0xb43ace7d,
    0x184adf63,
    0x82311ae5,
    0x60335197,
    0x457f5362,
    0xe07764b1,
    0x84ae6bbb,
    0x1ca081fe,
    0x942b08f9,
    0x58684870,
    0x19fd458f,
    0x876cde94,
    0xb7f87b52,
    0x23d373ab,
    0xe2024b72,
    0x578f1fe3,
    0x2aab5566,
    0x0728ebb2,
    0x03c2b52f,
    0x9a7bc586,
    0xa50837d3,
    0xf2872830,
    0xb2a5bf23,
    0xba6a0302,
    0x5c8216ed,
    0x2b1ccf8a,
    0x92b479a7,
    0xf0f207f3,
    0xa1e2694e,
    0xcdf4da65,
    0xd5be0506,
    0x1f6234d1,
    0x8afea6c4,
    0x9d532e34,
    0xa055f3a2,
    0x32e18a05,
    0x75ebf6a4,
    0x39ec830b,
    0xaaef6040,
    0x069f715e,
    0x51106ebd,
    0xf98a213e,
    0x3d06dd96,
    0xae053edd,
    0x46bde64d,
    0xb58d5491,
    0x055dc471,
    0x6fd40604,
    0xff155060,
    0x24fb9819,
    0x97e9bdd6,
    0xcc434089,
    0x779ed967,
    0xbd42e8b0,
    0x888b8907,
    0x385b19e7,
    0xdbeec879,
    0x470a7ca1,
    0xe90f427c,
    0xc91e84f8,
    0x00000000,
    0x83868009,
    0x48ed2b32,
    0xac70111e,
    0x4e725a6c,
    0xfbff0efd,
    0x5638850f,
    0x1ed5ae3d,
    0x27392d36,
    0x64d90f0a,
    0x21a65c68,
    0xd1545b9b,
    0x3a2e3624,
    0xb1670a0c,
    0x0fe75793,
    0xd296eeb4,
    0x9e919b1b,
    0x4fc5c080,
    0xa220dc61,
    0x694b775a,
    0x161a121c,
    0x0aba93e2,
    0xe52aa0c0,
    0x43e0223c,
    0x1d171b12,
    0x0b0d090e,
    0xadc78bf2,
    0xb9a8b62d,
    0xc8a91e14,
    0x8519f157,
    0x4c0775af,
    0xbbdd99ee,
    0xfd607fa3,
    0x9f2601f7,
    0xbcf5725c,
    0xc53b6644,
    0x347efb5b,
    0x7629438b,
    0xdcc623cb,
    0x68fcedb6,
    0x63f1e4b8,
    0xcadc31d7,
    0x10856342,
    0x40229713,
    0x2011c684,
    0x7d244a85,
    0xf83dbbd2,
    0x1132f9ae,
    0x6da129c7,
    0x4b2f9e1d,
    0xf330b2dc,
    0xec52860d,
    0xd0e3c177,
    0x6c16b32b,
    0x99b970a9,
    0xfa489411,
    0x2264e947,
    0xc48cfca8,
    0x1a3ff0a0,
    0xd82c7d56,
    0xef903322,
    0xc74e4987,
    0xc1d138d9,
    0xfea2ca8c,
    0x360bd498,
    0xcf81f5a6,
    0x28de7aa5,
    0x268eb7da,
    0xa4bfad3f,
    0xe49d3a2c,
    0x0d927850,
    0x9bcc5f6a,
    0x62467e54,
    0xc2138df6,
    0xe8b8d890,
    0x5ef7392e,
    0xf5afc382,
    0xbe805d9f,
    0x7c93d069,
    0xa92dd56f,
    0xb31225cf,
    0x3b99acc8,
    0xa77d1810,
    0x6e639ce8,
    0x7bbb3bdb,
    0x097826cd,
    0xf418596e,
    0x01b79aec,
    0xa89a4f83,
    0x656e95e6,
    0x7ee6ffaa,
    0x08cfbc21,
    0xe6e815ef,
    0xd99be7ba,
    0xce366f4a,
    0xd4099fea,
    0xd67cb029,
    0xafb2a431,
    0x31233f2a,
    0x3094a5c6,
    0xc066a235,
    0x37bc4e74,
    0xa6ca82fc,
    0xb0d090e0,
    0x15d8a733,
    0x4a9804f1,
    0xf7daec41,
    0x0e50cd7f,
    0x2ff69117,
    0x8dd64d76,
    0x4db0ef43,
    0x544daacc,
    0xdf0496e4,
    0xe3b5d19e,
    0x1b886a4c,
    0xb81f2cc1,
    0x7f516546,
    0x04ea5e9d,
    0x5d358c01,
    0x737487fa,
    0x2e410bfb,
    0x5a1d67b3,
    0x52d2db92,
    0x335610e9,
    0x1347d66d,
    0x8c61d79a,
    0x7a0ca137,
    0x8e14f859,
    0x893c13eb,
    0xee27a9ce,
    0x35c961b7,
    0xede51ce1,
    0x3cb1477a,
    0x59dfd29c,
    0x3f73f255,
    0x79ce1418,
    0xbf37c773,
    0xeacdf753,
    0x5baafd5f,
    0x146f3ddf,
    0x86db4478,
    0x81f3afca,
    0x3ec468b9,
    0x2c342438,
    0x5f40a3c2,
    0x72c31d16,
    0x0c25e2bc,
    0x8b493c28,
    0x41950dff,
    0x7101a839,
    0xdeb30c08,
    0x9ce4b4d8,
    0x90c15664,
    0x6184cb7b,
    0x70b632d5,
    0x745c6c48,
    0x4257b8d0
  ];

  int _shift(int r, int shift) => rotr32(r, shift);

  static const int _m1 = 0x80808080;
  static const int _m2 = 0x7f7f7f7f;
  static const int _m3 = 0x0000001b;
  static const int _m4 = 0xC0C0C0C0;
  static const int _m5 = 0x3f3f3f3f;

  int _fFmulX(int x) {
    var lsr = shiftr32(x & _m1, 7);
    return ((x & _m2) << 1) ^ lsr * _m3;
  }

  int _fFmulX2(int x) {
    var t0 = shiftl32(x & _m5, 2);
    var t1 = x & _m4;
    t1 ^= shiftr32(t1, 1);
    return t0 ^ shiftr32(t1, 2) ^ shiftr32(t1, 5);
  }

  int _invMcol(int x) {
    int t0, t1;
    t0 = x;
    t1 = t0 ^ _shift(t0, 8);
    t0 ^= _fFmulX(t1);
    t1 ^= _fFmulX2(t0);
    t0 ^= t1 ^ _shift(t1, 16);
    return t0;
  }

  int _subWord(int x) {
    return _S[x & 255] & 255 |
        ((_S[(x >> 8) & 255] & 255) << 8) |
        ((_S[(x >> 16) & 255] & 255) << 16) |
        _S[(x >> 24) & 255] << 24;
  }

  static const _blockSize = 16;

  @override
  int get blockSize => _blockSize;

  @override
  void reset() {}

  @override
  void init(bool forEncryption, covariant KeyParameter params) {
    _forEncryption = forEncryption;

    _workingKey = generateWorkingKey(forEncryption, params);

    if (_forEncryption) {
      _s = List.from(_S);
    } else {
      _s = List.from(_Si);
    }
  }

  List<List<int>> generateWorkingKey(bool forEncryption, KeyParameter params) {
    var key = params.key;
    var keyLen = key.length;
    if (keyLen < 16 || keyLen > 32 || (keyLen & 7) != 0) {
      throw ArgumentError('Key length not 128/192/256 bits.');
    }

    var kc = shiftr32(keyLen, 2);
    _rounds = kc + 6;

    var W = List.generate(
        _rounds + 1, (int i) => List<int>.filled(4, 0, growable: false));

    switch (kc) {
      case 4:
        final bKey = byteDataView(key);
        var col0 = unpack32(bKey, 0, Endian.little);
        W[0][0] = col0;
        var col1 = unpack32(bKey, 4, Endian.little);
        W[0][1] = col1;
        var col2 = unpack32(bKey, 8, Endian.little);
        W[0][2] = col2;
        var col3 = unpack32(bKey, 12, Endian.little);
        W[0][3] = col3;

        for (var i = 1; i <= 10; ++i) {
          var colx = _subWord(_shift(col3, 8)) ^ _rcon[i - 1];
          col0 ^= colx;
          W[i][0] = col0;
          col1 ^= col0;
          W[i][1] = col1;
          col2 ^= col1;
          W[i][2] = col2;
          col3 ^= col2;
          W[i][3] = col3;
        }
        break;
      case 6:
        final bKey = byteDataView(key);
        var col0 = unpack32(bKey, 0, Endian.little);
        W[0][0] = col0;
        var col1 = unpack32(bKey, 4, Endian.little);
        W[0][1] = col1;
        var col2 = unpack32(bKey, 8, Endian.little);
        W[0][2] = col2;
        var col3 = unpack32(bKey, 12, Endian.little);
        W[0][3] = col3;

        var col4 = unpack32(bKey, 16, Endian.little);
        var col5 = unpack32(bKey, 20, Endian.little);

        int i = 1, rcon = 1, colx;
        for (;;) {
          W[i][0] = col4;
          W[i][1] = col5;
          colx = _subWord(_shift(col5, 8)) ^ rcon;
          rcon <<= 1;
          col0 ^= colx;
          W[i][2] = col0;
          col1 ^= col0;
          W[i][3] = col1;

          col2 ^= col1;
          W[i + 1][0] = col2;
          col3 ^= col2;
          W[i + 1][1] = col3;
          col4 ^= col3;
          W[i + 1][2] = col4;
          col5 ^= col4;
          W[i + 1][3] = col5;

          colx = _subWord(_shift(col5, 8)) ^ rcon;
          rcon <<= 1;
          col0 ^= colx;
          W[i + 2][0] = col0;
          col1 ^= col0;
          W[i + 2][1] = col1;
          col2 ^= col1;
          W[i + 2][2] = col2;
          col3 ^= col2;
          W[i + 2][3] = col3;

          if ((i += 3) >= 13) {
            break;
          }

          col4 ^= col3;
          col5 ^= col4;
        }

        break;

      case 8:
        {
          final bKey = byteDataView(key);
          var col0 = unpack32(bKey, 0, Endian.little);
          W[0][0] = col0;
          var col1 = unpack32(bKey, 4, Endian.little);
          W[0][1] = col1;
          var col2 = unpack32(bKey, 8, Endian.little);
          W[0][2] = col2;
          var col3 = unpack32(bKey, 12, Endian.little);
          W[0][3] = col3;

          var col4 = unpack32(bKey, 16, Endian.little);
          W[1][0] = col4;
          var col5 = unpack32(bKey, 20, Endian.little);
          W[1][1] = col5;
          var col6 = unpack32(bKey, 24, Endian.little);
          W[1][2] = col6;
          var col7 = unpack32(bKey, 28, Endian.little);
          W[1][3] = col7;

          int i = 2, rcon = 1, colx;
          for (;;) {
            colx = _subWord(_shift(col7, 8)) ^ rcon;
            rcon <<= 1;
            col0 ^= colx;
            W[i][0] = col0;
            col1 ^= col0;
            W[i][1] = col1;
            col2 ^= col1;
            W[i][2] = col2;
            col3 ^= col2;
            W[i][3] = col3;
            ++i;

            if (i >= 15) {
              break;
            }

            colx = _subWord(col3);
            col4 ^= colx;
            W[i][0] = col4;
            col5 ^= col4;
            W[i][1] = col5;
            col6 ^= col5;
            W[i][2] = col6;
            col7 ^= col6;
            W[i][3] = col7;
            ++i;
          }

          break;
        }
      default:
        {
          throw StateError('Should never get here');
        }
    }

    if (!forEncryption) {
      for (var j = 1; j < _rounds; j++) {
        for (var i = 0; i < 4; i++) {
          W[j][i] = _invMcol(W[j][i]);
        }
      }
    }

    return W;
  }

  @override
  int processBlock(Uint8List inp, int inpOff, Uint8List out, int outOff) {
    if ((inpOff + (32 / 2)) > inp.lengthInBytes) {
      throw ArgumentError('Input buffer too short');
    }

    if ((outOff + (32 / 2)) > out.lengthInBytes) {
      throw ArgumentError('Output buffer too short');
    }

    if (_forEncryption) {
      _encryptBlock(inp, inpOff, out, outOff, _workingKey);
    } else {
      _decryptBlock(inp, inpOff, out, outOff, _workingKey);
    }

    return _blockSize;
  }

  void _encryptBlock(Uint8List input, int inOff, Uint8List out, int outOff,
      List<List<int>> kw) {
    final bInput = byteDataView(input);
    var c0 = unpack32(bInput, inOff + 0, Endian.little);
    var c1 = unpack32(bInput, inOff + 4, Endian.little);
    var c2 = unpack32(bInput, inOff + 8, Endian.little);
    var c3 = unpack32(bInput, inOff + 12, Endian.little);

    var t0 = c0 ^ kw[0][0];
    var t1 = c1 ^ kw[0][1];
    var t2 = c2 ^ kw[0][2];

    int r = 1, r0, r1, r2, r3 = c3 ^ kw[0][3];

    while (r < _rounds - 1) {
      r0 = _T0[t0 & 255] ^
          _shift(_T0[(t1 >> 8) & 255], 24) ^
          _shift(_T0[(t2 >> 16) & 255], 16) ^
          _shift(_T0[(r3 >> 24) & 255], 8) ^
          kw[r][0];
      r1 = _T0[t1 & 255] ^
          _shift(_T0[(t2 >> 8) & 255], 24) ^
          _shift(_T0[(r3 >> 16) & 255], 16) ^
          _shift(_T0[(t0 >> 24) & 255], 8) ^
          kw[r][1];
      r2 = _T0[t2 & 255] ^
          _shift(_T0[(r3 >> 8) & 255], 24) ^
          _shift(_T0[(t0 >> 16) & 255], 16) ^
          _shift(_T0[(t1 >> 24) & 255], 8) ^
          kw[r][2];
      r3 = _T0[r3 & 255] ^
          _shift(_T0[(t0 >> 8) & 255], 24) ^
          _shift(_T0[(t1 >> 16) & 255], 16) ^
          _shift(_T0[(t2 >> 24) & 255], 8) ^
          kw[r++][3];
      t0 = _T0[r0 & 255] ^
          _shift(_T0[(r1 >> 8) & 255], 24) ^
          _shift(_T0[(r2 >> 16) & 255], 16) ^
          _shift(_T0[(r3 >> 24) & 255], 8) ^
          kw[r][0];
      t1 = _T0[r1 & 255] ^
          _shift(_T0[(r2 >> 8) & 255], 24) ^
          _shift(_T0[(r3 >> 16) & 255], 16) ^
          _shift(_T0[(r0 >> 24) & 255], 8) ^
          kw[r][1];
      t2 = _T0[r2 & 255] ^
          _shift(_T0[(r3 >> 8) & 255], 24) ^
          _shift(_T0[(r0 >> 16) & 255], 16) ^
          _shift(_T0[(r1 >> 24) & 255], 8) ^
          kw[r][2];
      r3 = _T0[r3 & 255] ^
          _shift(_T0[(r0 >> 8) & 255], 24) ^
          _shift(_T0[(r1 >> 16) & 255], 16) ^
          _shift(_T0[(r2 >> 24) & 255], 8) ^
          kw[r++][3];
    }

    r0 = _T0[t0 & 255] ^
        _shift(_T0[(t1 >> 8) & 255], 24) ^
        _shift(_T0[(t2 >> 16) & 255], 16) ^
        _shift(_T0[(r3 >> 24) & 255], 8) ^
        kw[r][0];
    r1 = _T0[t1 & 255] ^
        _shift(_T0[(t2 >> 8) & 255], 24) ^
        _shift(_T0[(r3 >> 16) & 255], 16) ^
        _shift(_T0[(t0 >> 24) & 255], 8) ^
        kw[r][1];
    r2 = _T0[t2 & 255] ^
        _shift(_T0[(r3 >> 8) & 255], 24) ^
        _shift(_T0[(t0 >> 16) & 255], 16) ^
        _shift(_T0[(t1 >> 24) & 255], 8) ^
        kw[r][2];
    r3 = _T0[r3 & 255] ^
        _shift(_T0[(t0 >> 8) & 255], 24) ^
        _shift(_T0[(t1 >> 16) & 255], 16) ^
        _shift(_T0[(t2 >> 24) & 255], 8) ^
        kw[r++][3];

    c0 = (_S[r0 & 255] & 255) ^
        ((_S[(r1 >> 8) & 255] & 255) << 8) ^
        ((_s[(r2 >> 16) & 255] & 255) << 16) ^
        (_s[(r3 >> 24) & 255] << 24) ^
        kw[r][0];
    c1 = (_s[r1 & 255] & 255) ^
        ((_S[(r2 >> 8) & 255] & 255) << 8) ^
        ((_S[(r3 >> 16) & 255] & 255) << 16) ^
        (_s[(r0 >> 24) & 255] << 24) ^
        kw[r][1];
    c2 = (_s[r2 & 255] & 255) ^
        ((_S[(r3 >> 8) & 255] & 255) << 8) ^
        ((_S[(r0 >> 16) & 255] & 255) << 16) ^
        (_S[(r1 >> 24) & 255] << 24) ^
        kw[r][2];
    c3 = (_s[r3 & 255] & 255) ^
        ((_s[(r0 >> 8) & 255] & 255) << 8) ^
        ((_s[(r1 >> 16) & 255] & 255) << 16) ^
        (_S[(r2 >> 24) & 255] << 24) ^
        kw[r][3];

    pack32(c0, byteDataView(out), outOff + 0, Endian.little);
    pack32(c1, byteDataView(out), outOff + 4, Endian.little);
    pack32(c2, byteDataView(out), outOff + 8, Endian.little);
    pack32(c3, byteDataView(out), outOff + 12, Endian.little);
  }

  void _decryptBlock(Uint8List input, int inOff, Uint8List out, int outOff,
      List<List<int>> kw) {
    var c0 = unpack32(byteDataView(input), inOff + 0, Endian.little);
    var c1 = unpack32(byteDataView(input), inOff + 4, Endian.little);
    var c2 = unpack32(byteDataView(input), inOff + 8, Endian.little);
    var c3 = unpack32(byteDataView(input), inOff + 12, Endian.little);

    var t0 = c0 ^ kw[_rounds][0];
    var t1 = c1 ^ kw[_rounds][1];
    var t2 = c2 ^ kw[_rounds][2];

    int r = _rounds - 1, r0, r1, r2, r3 = c3 ^ kw[_rounds][3];
    while (r > 1) {
      r0 = _Tinv0[t0 & 255] ^
          _shift(_Tinv0[(r3 >> 8) & 255], 24) ^
          _shift(_Tinv0[(t2 >> 16) & 255], 16) ^
          _shift(_Tinv0[(t1 >> 24) & 255], 8) ^
          kw[r][0];
      r1 = _Tinv0[t1 & 255] ^
          _shift(_Tinv0[(t0 >> 8) & 255], 24) ^
          _shift(_Tinv0[(r3 >> 16) & 255], 16) ^
          _shift(_Tinv0[(t2 >> 24) & 255], 8) ^
          kw[r][1];
      r2 = _Tinv0[t2 & 255] ^
          _shift(_Tinv0[(t1 >> 8) & 255], 24) ^
          _shift(_Tinv0[(t0 >> 16) & 255], 16) ^
          _shift(_Tinv0[(r3 >> 24) & 255], 8) ^
          kw[r][2];
      r3 = _Tinv0[r3 & 255] ^
          _shift(_Tinv0[(t2 >> 8) & 255], 24) ^
          _shift(_Tinv0[(t1 >> 16) & 255], 16) ^
          _shift(_Tinv0[(t0 >> 24) & 255], 8) ^
          kw[r--][3];
      t0 = _Tinv0[r0 & 255] ^
          _shift(_Tinv0[(r3 >> 8) & 255], 24) ^
          _shift(_Tinv0[(r2 >> 16) & 255], 16) ^
          _shift(_Tinv0[(r1 >> 24) & 255], 8) ^
          kw[r][0];
      t1 = _Tinv0[r1 & 255] ^
          _shift(_Tinv0[(r0 >> 8) & 255], 24) ^
          _shift(_Tinv0[(r3 >> 16) & 255], 16) ^
          _shift(_Tinv0[(r2 >> 24) & 255], 8) ^
          kw[r][1];
      t2 = _Tinv0[r2 & 255] ^
          _shift(_Tinv0[(r1 >> 8) & 255], 24) ^
          _shift(_Tinv0[(r0 >> 16) & 255], 16) ^
          _shift(_Tinv0[(r3 >> 24) & 255], 8) ^
          kw[r][2];
      r3 = _Tinv0[r3 & 255] ^
          _shift(_Tinv0[(r2 >> 8) & 255], 24) ^
          _shift(_Tinv0[(r1 >> 16) & 255], 16) ^
          _shift(_Tinv0[(r0 >> 24) & 255], 8) ^
          kw[r--][3];
    }

    r0 = _Tinv0[t0 & 255] ^
        _shift(_Tinv0[(r3 >> 8) & 255], 24) ^
        _shift(_Tinv0[(t2 >> 16) & 255], 16) ^
        _shift(_Tinv0[(t1 >> 24) & 255], 8) ^
        kw[r][0];
    r1 = _Tinv0[t1 & 255] ^
        _shift(_Tinv0[(t0 >> 8) & 255], 24) ^
        _shift(_Tinv0[(r3 >> 16) & 255], 16) ^
        _shift(_Tinv0[(t2 >> 24) & 255], 8) ^
        kw[r][1];
    r2 = _Tinv0[t2 & 255] ^
        _shift(_Tinv0[(t1 >> 8) & 255], 24) ^
        _shift(_Tinv0[(t0 >> 16) & 255], 16) ^
        _shift(_Tinv0[(r3 >> 24) & 255], 8) ^
        kw[r][2];
    r3 = _Tinv0[r3 & 255] ^
        _shift(_Tinv0[(t2 >> 8) & 255], 24) ^
        _shift(_Tinv0[(t1 >> 16) & 255], 16) ^
        _shift(_Tinv0[(t0 >> 24) & 255], 8) ^
        kw[r][3];

    c0 = (_Si[r0 & 255] & 255) ^
        ((_s[(r3 >> 8) & 255] & 255) << 8) ^
        ((_s[(r2 >> 16) & 255] & 255) << 16) ^
        (_Si[(r1 >> 24) & 255] << 24) ^
        kw[0][0];
    c1 = (_s[r1 & 255] & 255) ^
        ((_s[(r0 >> 8) & 255] & 255) << 8) ^
        ((_Si[(r3 >> 16) & 255] & 255) << 16) ^
        (_s[(r2 >> 24) & 255] << 24) ^
        kw[0][1];
    c2 = (_s[r2 & 255] & 255) ^
        ((_Si[(r1 >> 8) & 255] & 255) << 8) ^
        ((_Si[(r0 >> 16) & 255] & 255) << 16) ^
        (_s[(r3 >> 24) & 255] << 24) ^
        kw[0][2];
    c3 = (_Si[r3 & 255] & 255) ^
        ((_s[(r2 >> 8) & 255] & 255) << 8) ^
        ((_s[(r1 >> 16) & 255] & 255) << 16) ^
        (_s[(r0 >> 24) & 255] << 24) ^
        kw[0][3];

    final bOut = byteDataView(out);
    pack32(c0, bOut, outOff + 0, Endian.little);
    pack32(c1, bOut, outOff + 4, Endian.little);
    pack32(c2, bOut, outOff + 8, Endian.little);
    pack32(c3, bOut, outOff + 12, Endian.little);
  }
}

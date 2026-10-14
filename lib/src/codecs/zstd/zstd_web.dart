import 'dart:typed_data';

// Compile time, so each build keeps one arm of every 64 bit branch and drops
// the other. A runtime flag would leave both in every hot loop
const zstdUse64Bit = bool.fromEnvironment('dart.library.isolate');

// dart2js truncates a shift to 32 bits, so a left shift is a multiply and the
// mask keeps the product exact
int zstdWebShift(int value, int count) =>
    count == 0 ? value : (value & (_powers[32 - count] - 1)) * _powers[count];

const _powers = <int>[
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128,
  256,
  512,
  1024,
  2048,
  4096,
  8192,
  16384,
  32768,
  65536,
  131072,
  262144,
  524288,
  1048576,
  2097152,
  4194304,
  8388608,
  16777216,
  33554432,
  67108864,
  134217728,
  268435456,
  536870912,
  1073741824,
  2147483648,
  4294967296,
];

const _keyLow = [0, 0, 0, 0, 0, 0xbb000000, 0xbf9b0000, 0xbfa56300, 0xb7a56463];

int zstdWebKey(ByteData view, int at, int bytes, int shift) {
  final lo = view.getUint32(at, Endian.little);
  final hi = view.getUint32(at + 4, Endian.little);
  final mulHi = bytes == 4 ? 0x9e3779b1 : 0xcf1bbcdc;
  final mulLo = _keyLow[bytes];
  final a0 = lo & 0xffff;
  final a1 = lo >>> 16;
  final a2 = hi & 0xffff;
  final a3 = hi >>> 16;
  final b0 = mulLo & 0xffff;
  final b1 = mulLo >>> 16;
  final b2 = mulHi & 0xffff;
  final b3 = mulHi >>> 16;
  var carry = a0 * b0;
  final r0 = carry & 0xffff;
  carry = (carry ~/ 65536) + a0 * b1 + a1 * b0;
  final r1 = carry & 0xffff;
  carry = (carry ~/ 65536) + a0 * b2 + a1 * b1 + a2 * b0;
  final r2 = carry & 0xffff;
  carry = (carry ~/ 65536) + a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;
  final upper = r2 + (carry & 0xffff) * 65536;
  if (shift >= 32) return upper >>> (shift - 32);
  return upper * _powers[32 - shift] + ((r0 + r1 * 65536) >>> shift);
}

bool zstdWebSame8(ByteData view, int a, int b) =>
    view.getUint32(a, Endian.little) == view.getUint32(b, Endian.little) &&
    view.getUint32(a + 4, Endian.little) ==
        view.getUint32(b + 4, Endian.little);

int zstdWebMultiply32(int a, int b) {
  final low = (a & 0xffff) * (b & 0xffff);
  final cross = (a >>> 16) * (b & 0xffff) + (a & 0xffff) * (b >>> 16);
  return (low + (cross & 0xffff) * 65536) & 0xffffffff;
}

int zstdWebCount(Uint8List src, ByteData view, int a, int b, int end) {
  var length = 0;
  while (a + length + 4 <= end &&
      view.getUint32(a + length, Endian.little) ==
          view.getUint32(b + length, Endian.little)) {
    length += 4;
  }
  while (a + length < end && src[a + length] == src[b + length]) {
    length++;
  }
  return length;
}

class ZstdFseScale {
  static const _base = 2097152;
  final int accuracyLog;
  final int _pointScale;
  int _stepHigh = 0;
  int _stepMiddle = 0;
  int _stepLow = 0;
  int _high = 0;
  int _middle = 0;
  int _low = 0;
  int _runningHigh = 0;
  int _runningMiddle = 0;
  int _runningLow = 0;

  ZstdFseScale.normalize(int total, this.accuracyLog)
      : _pointScale = 1 << (20 - accuracyLog) {
    _divide(1048576, 0, 0, total);
  }

  ZstdFseScale.remainder(int total, int points, this.accuracyLog)
      : _pointScale = 1 << (20 - accuracyLog) {
    _runningHigh = (_pointScale >> 1) - 1;
    _runningMiddle = _base - 1;
    _runningLow = _base - 1;
    _divide(points * _pointScale + _runningHigh, _runningMiddle, _runningLow,
        total);
  }

  // 21-bit limbs keep a limb times a 32-bit count within exact JS integers
  void _divide(int high, int middle, int low, int divisor) {
    _stepHigh = high ~/ divisor;
    final next = (high % divisor) * _base + middle;
    _stepMiddle = next ~/ divisor;
    _stepLow = ((next % divisor) * _base + low) ~/ divisor;
  }

  void _multiply(int count) {
    final low = count * _stepLow;
    final middle = count * _stepMiddle + low ~/ _base;
    _low = low % _base;
    _middle = middle % _base;
    _high = count * _stepHigh + middle ~/ _base;
  }

  int probability(int count, List<int> roundUpAt) {
    _multiply(count);
    var points = _high ~/ _pointScale;
    if (points < 8) {
      final remainder = _high - points * _pointScale;
      final threshold = roundUpAt[points];
      final high = threshold >> accuracyLog;
      final middle =
          (threshold & ((1 << accuracyLog) - 1)) << (21 - accuracyLog);
      if (remainder > high ||
          (remainder == high &&
              (_middle > middle || (_middle == middle && _low != 0)))) {
        points++;
      }
    }
    return points;
  }

  int advance(int count) {
    final before = _runningHigh ~/ _pointScale;
    _multiply(count);
    final low = _runningLow + _low;
    final middle = _runningMiddle + _middle + low ~/ _base;
    _runningLow = low % _base;
    _runningMiddle = middle % _base;
    _runningHigh += _high + middle ~/ _base;
    return _runningHigh ~/ _pointScale - before;
  }
}

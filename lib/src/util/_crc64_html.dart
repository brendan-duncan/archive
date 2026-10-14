import 'dart:typed_data';

bool isCrc64Supported_() => false;

int getCrc64_(List<int> array, [int crc = 0]) {
  throw UnsupportedError('Crc64 is not support on html');
}

/// The reflected ECMA-182 polynomial, the halves of 0xc96c5795d7870f42
const _polynomialHigh = 0xc96c5795;
const _polynomialLow = 0xd7870f42;

/// Built rather than written out. A web int stops at 53 bits and cannot spell
/// the 64 bit literals the other backend holds
final Uint32List _tableHigh = _buildTable(true);
final Uint32List _tableLow = _buildTable(false);

Uint32List _buildTable(bool wantHigh) {
  final out = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var low = i;
    var high = 0;
    for (var bit = 0; bit < 8; bit++) {
      final carry = low & 1;
      low = ((low >>> 1) | ((high & 1) << 31)) & 0xffffffff;
      high = high >>> 1;
      if (carry != 0) {
        low ^= _polynomialLow;
        high ^= _polynomialHigh;
      }
    }
    out[i] = wantHigh ? high : low;
  }
  return out;
}

final Uint32List _sliceHigh = _buildSlices(true);
final Uint32List _sliceLow = _buildSlices(false);

Uint32List _buildSlices(bool wantHigh) {
  final low = Uint32List(8 * 256)..setRange(0, 256, _tableLow);
  final high = Uint32List(8 * 256)..setRange(0, 256, _tableHigh);
  for (var k = 1; k < 8; k++) {
    for (var i = 0; i < 256; i++) {
      final lo = low[(k - 1) * 256 + i];
      final hi = high[(k - 1) * 256 + i];
      final index = lo & 0xff;
      low[k * 256 + i] =
          (((lo >>> 8) | ((hi & 0xff) << 24)) ^ _tableLow[index]) & 0xffffffff;
      high[k * 256 + i] = ((hi >>> 8) ^ _tableHigh[index]) & 0xffffffff;
    }
  }
  return wantHigh ? high : low;
}

/// A running CRC-64 held as two 32 bit halves. No other shape survives a
/// backend whose int is not 64 bits wide
class Crc64Core {
  var _high = 0;
  var _low = 0;

  void reset() {
    _high = 0;
    _low = 0;
  }

  /// The state is the finished value, so the initial and final inversions go
  /// on and come off around each call, the way [getCrc64_] chains
  void update(List<int> array) {
    final tableHigh = _tableHigh;
    final tableLow = _tableLow;
    var high = _high ^ 0xffffffff;
    var low = _low ^ 0xffffffff;
    var i = 0;
    if (array is Uint8List) {
      final sliceHigh = _sliceHigh;
      final sliceLow = _sliceLow;
      final bytes =
          ByteData.view(array.buffer, array.offsetInBytes, array.length);
      final limit = array.length - 8;
      while (i <= limit) {
        final l = (low ^ bytes.getUint32(i, Endian.little)) & 0xffffffff;
        final h = (high ^ bytes.getUint32(i + 4, Endian.little)) & 0xffffffff;
        low = sliceLow[1792 + (l & 0xff)] ^
            sliceLow[1536 + ((l >>> 8) & 0xff)] ^
            sliceLow[1280 + ((l >>> 16) & 0xff)] ^
            sliceLow[1024 + (l >>> 24)] ^
            sliceLow[768 + (h & 0xff)] ^
            sliceLow[512 + ((h >>> 8) & 0xff)] ^
            sliceLow[256 + ((h >>> 16) & 0xff)] ^
            sliceLow[h >>> 24];
        high = sliceHigh[1792 + (l & 0xff)] ^
            sliceHigh[1536 + ((l >>> 8) & 0xff)] ^
            sliceHigh[1280 + ((l >>> 16) & 0xff)] ^
            sliceHigh[1024 + (l >>> 24)] ^
            sliceHigh[768 + (h & 0xff)] ^
            sliceHigh[512 + ((h >>> 8) & 0xff)] ^
            sliceHigh[256 + ((h >>> 16) & 0xff)] ^
            sliceHigh[h >>> 24];
        i += 8;
      }
    }
    for (; i < array.length; i++) {
      final index = (low ^ array[i]) & 0xff;
      final shiftedLow = ((low >>> 8) | ((high & 0xff) << 24)) & 0xffffffff;
      low = (shiftedLow ^ tableLow[index]) & 0xffffffff;
      high = ((high >>> 8) ^ tableHigh[index]) & 0xffffffff;
    }
    _high = high ^ 0xffffffff;
    _low = low ^ 0xffffffff;
  }

  int get high32 => _high;

  int get low32 => _low;
}

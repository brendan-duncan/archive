import 'dart:typed_data';
import 'zstd_web.dart';

/// Writes the bitstreams the format reads backwards. At most 63 bits stand
/// unflushed. The shift masks below are no-ops because of it
class ZstdBitWriter {
  final ByteData view;

  int _container = 0;
  int _high = 0;
  int _bits = 0;
  int _at;

  ZstdBitWriter(this.view, [int start = 0]) : _at = start;

  /// Counts are masked so the shift compiles without a range guard and slow
  /// path
  @pragma('vm:prefer-inline')
  void add(int value, int count) {
    if (!zstdUse64Bit) {
      addClean(count >= 32 ? value : value & ((1 << count) - 1), count);
      return;
    }
    _container |= (value & ((1 << (count & 63)) - 1)) << (_bits & 63);
    _bits += count;
  }

  /// [value] must have nothing set above [count]
  @pragma('vm:prefer-inline')
  void addClean(int value, int count) {
    if (!zstdUse64Bit) {
      final at = _bits & 63;
      if (at >= 32) {
        _high |= zstdWebShift(value, at - 32);
      } else {
        _container |= zstdWebShift(value, at);
        if (at > 0) _high |= value >>> (32 - at);
      }
      _bits += count;
      return;
    }
    _container |= value << (_bits & 63);
    _bits += count;
  }

  @pragma('vm:prefer-inline')
  void flush() {
    if (!zstdUse64Bit) {
      final bytes = _bits >> 3;
      view.setUint32(_at, _container, Endian.little);
      view.setUint32(_at + 4, _high, Endian.little);
      _at += bytes;
      _bits &= 7;
      final shift = (bytes << 3) & 63;
      if (shift >= 32) {
        _container = _high >>> (shift - 32);
        _high = 0;
      } else if (shift > 0) {
        _container = (_container >>> shift) | zstdWebShift(_high, 32 - shift);
        _high >>>= shift;
      }
      return;
    }
    final bytes = _bits >> 3;
    view.setUint64(_at, _container, Endian.little);
    _at += bytes;
    _bits &= 7;
    _container >>>= (bytes << 3) & 63;
  }

  /// Adds the marker bit the reader looks for
  int close() {
    addClean(1, 1);
    flush();
    return _at + (_bits > 0 ? 1 : 0);
  }
}

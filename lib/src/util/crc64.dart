// CRC-64 needs an int wide enough to hold the polynomial, so it exists only on
// the backends where an int is a real 64 bit integer. Everywhere else
// [isCrc64Supported] reports false and callers fall back.
//
// The condition asks about integer width, not about dart:io: the
// implementation below imports nothing but dart:typed_data. dart:isolate is
// available on exactly the VM and wasm, which are exactly the backends whose
// ints are 64 bit, so that is what selects it. The unsupported stub is the
// default, so an unrecognised backend loses CRC-64 rather than miscompiling.
//
// This used to key off dart.library.html, which is false on JavaScript targets
// that have no dart:html, such as dart2js targeting Node. Those ended up with
// the 64 bit table and failed to compile at all, on literals like
// 0xb32e4cbe03a75f6f that JavaScript cannot represent.
import 'dart:typed_data';

import '_crc64_html.dart' if (dart.library.isolate) '_crc64_io.dart';

/// Throws UnsupportedError on dart2js, where int holds 53 bits. Use [Crc64]
/// instead, which holds CRC as two 32-bit halves and returns 8 bytes, so it
/// works on every backend without speed downgrade for IO
int getCrc64(List<int> array, [int crc = 0]) => getCrc64_(array, crc);

/// False on dart2js, where int holds 53 bits and [getCrc64] cannot return
/// 64-bit value. Use [Crc64], which holds CRC as two 32-bit halves and returns
/// 8 bytes, so it works on every backend without speed downgrade for IO
bool isCrc64Supported() => isCrc64Supported_();

/// A running CRC-64 over however many pieces the bytes arrive in, on every
/// backend. The value leaves as eight little endian bytes rather than as an
/// int, since an int does not hold it where dart2js compiles
class Crc64 {
  final Crc64Core _core = Crc64Core();

  void reset() => _core.reset();

  void update(List<int> array) => _core.update(array);

  /// The check as the format stores it, eight bytes little endian
  Uint8List get bytes {
    final low = _core.low32;
    final high = _core.high32;
    return Uint8List.fromList([
      low & 0xff,
      (low >>> 8) & 0xff,
      (low >>> 16) & 0xff,
      (low >>> 24) & 0xff,
      high & 0xff,
      (high >>> 8) & 0xff,
      (high >>> 16) & 0xff,
      (high >>> 24) & 0xff,
    ]);
  }

  /// Whether the eight bytes of [stored] starting at [at] are this check
  bool matches(List<int> stored, int at) {
    if (at + 8 > stored.length) {
      return false;
    }
    final want = bytes;
    for (var i = 0; i < 8; i++) {
      if (stored[at + i] != want[i]) {
        return false;
      }
    }
    return true;
  }
}

/// The check over [array] whole, for a caller with nothing to keep between
/// pieces
Uint8List crc64Bytes(List<int> array) => (Crc64()..update(array)).bytes;

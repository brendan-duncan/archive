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
import '_crc64_html.dart' if (dart.library.isolate) '_crc64_io.dart';

int getCrc64(List<int> array, [int crc = 0]) => getCrc64_(array, crc);

bool isCrc64Supported() => isCrc64Supported_();

import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

typedef _Decoder = Uint8List Function(Uint8List input);

void main() {
  final source = Uint8List.fromList(
    List<int>.generate(1024, (i) => (i * 19 + (i ~/ 31)) & 0xff),
  );
  const maxOutput = 8192;
  final codecs = <(String, Uint8List, _Decoder)>[
    (
      'gzip',
      GZipEncoder().encodeBytes(source),
      (input) => GZipDecoder().decodeBytes(input,
          verify: true, throwOnError: true, maxOutputSize: maxOutput),
    ),
    (
      'zlib',
      ZLibEncoder().encodeBytes(source),
      (input) => ZLibDecoder().decodeBytes(input,
          verify: true, throwOnError: true, maxOutputSize: maxOutput),
    ),
    (
      'bzip2',
      BZip2Encoder().encodeBytes(source),
      (input) => BZip2Decoder().decodeBytes(input,
          verify: true, throwOnError: true, maxOutputSize: maxOutput),
    ),
    (
      'xz',
      XZEncoder().encodeBytes(source),
      (input) => XZDecoder().decodeBytes(input,
          verify: true, throwOnError: true, maxOutputSize: maxOutput),
    ),
    (
      'zstd',
      ZstdEncoder().encodeBytes(source, checksum: true),
      (input) => ZstdDecoder().decodeBytes(input,
          verify: true, throwOnError: true, maxOutputSize: maxOutput),
    ),
  ];

  for (final (name, compressed, decode) in codecs) {
    test('$name: verified mutations must reject or preserve exact content',
        () {
      expect(decode(compressed), source);
      final rng = Random(0x63245 + name.codeUnits.length);
      for (var i = 0; i < 80; i++) {
        final broken = Uint8List.fromList(compressed);
        final offset = rng.nextInt(broken.length);
        broken[offset] ^= 1 << rng.nextInt(8);
        try {
          expect(decode(broken), source,
              reason: '$name accepted a silent content mutation $i at $offset');
        } on ArchiveException {
          // A verified decoder may reject any damaged header or payload.
        }
      }
    });

    test('$name: deterministic malformed short data remains within limit',
        () {
      final rng = Random(0x17219 + name.length);
      for (var i = 0; i < 250; i++) {
        final length = rng.nextInt(80);
        final bytes = Uint8List.fromList(
          List<int>.generate(length, (_) => rng.nextInt(256)),
        );
        try {
          expect(decode(bytes).length, lessThanOrEqualTo(maxOutput),
              reason: '$name unexpected output at case $i');
        } on ArchiveException {
          // Invalid format data must not leak raw RangeError/TypeError.
        }
      }
    });
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  group('dynamic Huffman table validation', () {
    final archives = {
      'incomplete code length table':
          'eJwFwAEIAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQAAAAE=',
      'incomplete literal table':
          'eJwFwAEEAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAEAAAAB',
      'incomplete distance table':
          'eJwFwAEEAAAAgCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAYAAAAB',
      'single bit tables':
          'eJwFwAEEAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAEAAAAB',
      'unused distance table':
          'eJwFwAEEAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAB',
    };
    for (final entry in archives.entries) {
      test(entry.key, () {
        final zlib = base64Decode(entry.value);
        final raw = zlib.sublist(2, zlib.length - 4);
        final gzip = [
          31,
          139,
          8,
          0,
          0,
          0,
          0,
          0,
          0,
          3,
          ...raw,
          ...List.filled(8, 0)
        ];
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          final decodes = <void Function()>[
            () => ZLibDecoderWeb()
                .decodeBytes(zlib, verify: verify, throwOnError: throwOnError),
            () => ZLibDecoderWeb().decodeStream(
                InputMemoryStream(zlib), OutputMemoryStream(),
                verify: verify, throwOnError: throwOnError),
            () => ZLibDecoderWeb().decodeBytes(raw,
                raw: true, verify: verify, throwOnError: throwOnError),
            () => GZipDecoderWeb()
                .decodeBytes(gzip, verify: verify, throwOnError: throwOnError),
            () => GZipDecoderWeb().decodeStream(
                InputMemoryStream(gzip), OutputMemoryStream(),
                verify: verify, throwOnError: throwOnError),
          ];
          for (final decode in decodes) {
            expect(
                decode,
                entry.key.startsWith('incomplete')
                    ? throwsA(isA<ArchiveException>())
                    : returnsNormally,
                reason: 'verify $verify, throwOnError $throwOnError');
          }
        }
      });
    }
  });

  final buffer = Uint8List(0xfffff);
  for (var i = 0; i < buffer.length; ++i) {
    buffer[i] = i % 256;
  }

  test('NO_COMPRESSION', () {
    final deflated = Deflate(buffer, level: DeflateLevel.none).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_SPEED', () {
    final deflated = Deflate(buffer, level: DeflateLevel.bestSpeed).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_COMPRESSION', () {
    final deflated =
        Deflate(buffer, level: DeflateLevel.bestCompression).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });
}

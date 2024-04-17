import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() async {
  final buffer = Uint8List(10000);
  for (var i = 0; i < buffer.length; ++i) {
    buffer[i] = i % 256;
  }

  group('ZLib', () {
    test('encode/decode', () async {
      final compressed = const ZLibEncoder().encodeBytes(buffer);
      final decompressed =
          const ZLibDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('encodeStream', () async {
      {
        final outStream = OutputFileStream('$testOutputPath/zlib_stream.zlib')
          ..open();
        final inStream = InputMemoryStream(buffer);
        const ZLibEncoder().encodeStream(inStream, outStream);
      }

      {
        final inStream = InputFileStream('$testOutputPath/zlib_stream.zlib')
          ..open();
        final decoded = const ZLibDecoder().decodeStream(inStream);

        expect(decoded.length, equals(buffer.length));
        for (var i = 0; i < buffer.length; ++i) {
          expect(decoded[i], equals(buffer[i]));
        }
      }
    });
  });
}

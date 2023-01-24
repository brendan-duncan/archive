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
      final compressed = await const ZLibEncoder().encodeBytes(buffer);
      final decompressed = await const ZLibDecoder().decodeBytes(compressed,
          verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('encodeStream', () async {
      {
        final outStream = OutputStreamFile('$testOutputPath/zlib_stream.zlib');
        await outStream.open();
        final inStream = InputStreamMemory(buffer);
        await const ZLibEncoder().encodeStream(inStream, outStream);
      }

      {
        final inStream = InputStreamFile('$testOutputPath/zlib_stream.zlib');
        await inStream.open();
        final decoded = await const ZLibDecoder().decodeStream(inStream);

        expect(decoded.length, equals(buffer.length));
        for (var i = 0; i < buffer.length; ++i) {
          expect(decoded[i], equals(buffer[i]));
        }
      }
    });
  });
}

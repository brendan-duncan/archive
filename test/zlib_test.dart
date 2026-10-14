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
    test('multiblock', () async {
      final compressedData = [
        ...ZLibEncoder().encodeBytes([1, 2, 3]),
        ...ZLibEncoder().encodeBytes([4, 5, 6])
      ];
      final decodedData =
          ZLibDecoderWeb().decodeBytes(compressedData, verify: true);
      compareBytes(decodedData, [1, 2, 3]);
    });

    test('encode/decode', () async {
      final compressed = const ZLibEncoder().encodeBytes(buffer);
      final decompressed =
          const ZLibDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('encodeStream', testOn: 'vm', () async {
      {
        final outStream = OutputFileStream('$testOutputPath/zlib_stream.zlib')
          ..open();
        final inStream = InputMemoryStream(buffer);
        const ZLibEncoder().encodeStream(inStream, outStream);
      }

      {
        final inStream = InputFileStream('$testOutputPath/zlib_stream.zlib')
          ..open();
        final outStream = OutputMemoryStream();
        ZLibDecoder().decodeStream(inStream, outStream);
        final decoded = outStream.getBytes();

        expect(decoded.length, equals(buffer.length));
        for (var i = 0; i < buffer.length; ++i) {
          expect(decoded[i], equals(buffer[i]));
        }
      }
    });

    test('small decodeBytes result is not view of larger output buffer',
        testOn: 'vm', () {
      final data = [1, 2, 3, 4, 5];
      for (final raw in [false, true]) {
        final packed = raw
            ? Deflate(data).getBytes()
            : const ZLibEncoder().encodeBytes(data);
        for (final (verify, throwOnError) in [
          (false, false),
          (false, true),
          (true, false)
        ]) {
          final out = ZLibDecoder().decodeBytes(packed,
              raw: raw, verify: verify, throwOnError: throwOnError);
          expect(out, data);
          expect(out.buffer.lengthInBytes, data.length,
              reason: 'raw $raw, verify $verify, throwOnError $throwOnError');
        }
      }
    });
  });
}

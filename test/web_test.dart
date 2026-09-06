import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('zlib web', () {
    test('encode/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoder().encodeBytes(origData);
      final uncompressed = ZLibDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });
  });

  group('gzip web', () {
    final buffer = Uint8List(10000);
    for (var i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('encode/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoder().encodeBytes(origData);
      final uncompressed = GZipDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('multiblock', () async {
      final compressedData = [
        ...GZipEncoder().encodeBytes([1, 2, 3]),
        ...GZipEncoder().encodeBytes([4, 5, 6])
      ];
      final decodedData =
          GZipDecoderWeb().decodeBytes(compressedData, verify: true);
      compareBytes(decodedData, [1, 2, 3, 4, 5, 6]);
    });

    test('encode/decode', () {
      final compressed = GZipEncoder().encodeBytes(buffer);
      final decompressed = GZipDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });
  });

  group('tar web', () {
    // On the web an int is a double and the bitwise operators are 32 bit, so
    // a base 256 header field has to be read with arithmetic to survive the
    // trip. 9437184000 needs 34 bits and would come back truncated otherwise.
    test('base 256 size', () {
      final h = Uint8List(1024);
      h.setRange(0, 5, 'a.txt'.codeUnits);
      h.setRange(124, 136, [0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x32, 0x80, 0, 0]);
      h[156] = 0x30; // normal file
      h.setRange(257, 263, 'ustar '.codeUnits);

      final decoder = TarDecoder();
      decoder.decodeBytes(h, storeData: false);
      expect(decoder.files.length, equals(1));
      expect(decoder.files[0].fileSize, equals(9437184000));
    });
  });
}

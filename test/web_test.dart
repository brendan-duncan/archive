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

    test('an input too short for a header is refused, not thrown', () {
      // Without a gzip header the gzip decoder falls back to zlib, whose own
      // two byte header was read unchecked
      final short = Uint8List(1);
      expect(
          ZLibDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
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

    test('verify checks the member CRC', () {
      final compressed = GZipEncoder().encodeBytes(buffer);
      expect(GZipDecoderWeb().decodeBytes(compressed, verify: true).length,
          equals(buffer.length));

      // The stored checksum, not the data: the length still matches, so only
      // the checksum is left to notice
      final damaged = Uint8List.fromList(compressed);
      damaged[damaged.length - 8] ^= 0xff;
      expect(
          GZipDecoderWeb().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: true),
          isFalse);
      // A second pass over the output, so without verify it is not read
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(damaged), OutputMemoryStream()),
          isTrue);
    });

    test('damage is reported by return value, not thrown', () {
      // These used to come out as a RangeError from inside the decoder
      final compressed = GZipEncoder().encodeBytes(buffer);
      // Bytes that damage a match into reaching back past the output
      for (final at in [18, 19, 20, 21, 22, 23, 154, 158, 164]) {
        final damaged = Uint8List.fromList(compressed);
        damaged[at] ^= 0xff;
        expect(
            GZipDecoderWeb()
                .decodeStream(InputMemoryStream(damaged), OutputMemoryStream()),
            isFalse,
            reason: 'byte $at');
      }

      // A header whose optional fields claim more than the input holds
      final short = Uint8List.fromList(compressed.take(12).toList());
      short[3] = 0x1f; // extra, name, comment and hcrc all present
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
    });

    test('damage is a return value with a file output too', () {
      // Behind a file output a match reaching back past the start used to
      // seek to a negative position and throw, where the memory output threw
      // a RangeError that was caught. Inflate now refuses the match itself
      final compressed = GZipEncoder().encodeBytes(buffer);
      final path = '$testOutputPath/damaged.bin';
      for (final at in [18, 19, 20, 21, 22, 23, 154, 158, 164]) {
        final damaged = Uint8List.fromList(compressed);
        damaged[at] ^= 0xff;
        // A small buffer, so the output has been flushed by the time the
        // bad match arrives
        final out = OutputFileStream(path, bufferSize: 64);
        expect(GZipDecoderWeb().decodeStream(InputMemoryStream(damaged), out),
            isFalse,
            reason: 'byte $at');
        out.closeSync();
      }
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
    // trip. 9437184000 needs 34 bits and would come back truncated otherwise
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

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('gzip', () {
    final buffer = Uint8List(10000);
    for (var i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('zlib encode_web/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoderWeb().encodeBytes(origData);
      final uncompressed = ZLibDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('zlib encode/decode_web', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoder().encodeBytes(origData);
      final uncompressed = ZLibDecoderWeb().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('gzip encode_web/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoderWeb().encodeBytes(origData);
      final uncompressed = GZipDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('gzip encode/decode_web', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoder().encodeBytes(origData);
      final uncompressed = GZipDecoderWeb().decodeBytes(compressed);
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

    test('decode res/cat.jpg.gz', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/cat.jpg.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/test2.tar.gz', () {
      final b = File('test/_data/test2.tar');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/test2.tar.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/a.txt.gz', () {
      final aBytes = aTxt.codeUnits;

      final file = File('test/_data/a.txt.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, aBytes);
    });

    test('encode res/cat.jpg', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final compressed = GZipEncoder().encodeBytes(bBytes);
      final f = File('$testOutputPath/cat.jpg.gz');
      f.createSync(recursive: true);
      f.writeAsBytesSync(compressed);
    });

    group('a truncated stream is reported', () {
      // The decoder underneath checks every member whose trailer it reaches,
      // so what is at stake here is the one case it cannot see: a member that
      // ends before its trailer. Left unreported that decodes to a short
      // result and returns true, which for a .tar.gz means files quietly
      // going missing.
      final whole = Uint8List.fromList(GZipEncoder().encodeBytes(buffer));

      int decode(GZipDecoder decoder, Uint8List data, {required bool ok}) {
        final output = OutputMemoryStream();
        expect(decoder.decodeStream(InputMemoryStream(data), output), ok);
        return output.length;
      }

      int decodeWeb(Uint8List data, {required bool ok}) {
        final output = OutputMemoryStream();
        expect(
            GZipDecoderWeb().decodeStream(InputMemoryStream(data), output), ok);
        return output.length;
      }

      test('whole input decodes and reports success', () {
        expect(decode(GZipDecoder(), whole, ok: true), buffer.length);
        expect(decodeWeb(whole, ok: true), buffer.length);
      });

      // Eight bytes is exactly the trailer, so this covers losing the trailer
      // alone as well as losing compressed data with it.
      for (final cut in [1, 8, 9, 40]) {
        test('$cut bytes short', () {
          final short = Uint8List.sublistView(whole, 0, whole.length - cut);
          decode(GZipDecoder(), short, ok: false);
          decodeWeb(short, ok: false);
        });
      }

      test('concatenated members are not mistaken for one', () {
        // Every member but the last is checked by the decoder itself, so the
        // point here is that the check added for the last one does not go off
        // on a stream that is whole.
        final two = Uint8List.fromList([...whole, ...whole]);
        expect(decode(GZipDecoder(), two, ok: true), buffer.length * 2);
        expect(decodeWeb(two, ok: true), buffer.length * 2);

        final cut = Uint8List.sublistView(two, 0, two.length - 40);
        decode(GZipDecoder(), cut, ok: false);
        decodeWeb(cut, ok: false);
      });

      test('an empty input is not an empty archive', () {
        decode(GZipDecoder(), Uint8List(0), ok: false);
        decodeWeb(Uint8List(0), ok: false);
      });

      test('a zlib stream still goes through unremarked', () {
        // Both decoders accept a stream with no gzip header at all, to match
        // what dart:io does. Its trailer is four bytes of Adler-32, which the
        // check above would fail on sight, so it must not be reached.
        for (final data in [
          Uint8List.fromList(ZLibEncoder().encodeBytes(buffer)),
          Uint8List.fromList(ZLibEncoder().encodeBytes(Uint8List(0))),
          Uint8List.fromList(ZLibEncoderWeb().encodeBytes(buffer)),
        ]) {
          final output = OutputMemoryStream();
          expect(GZipDecoder().decodeStream(InputMemoryStream(data), output),
              isTrue);
          expect(
              GZipDecoderWeb()
                  .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
              isTrue);
        }
      });
    });
  });
}

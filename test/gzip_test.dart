import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('gzi', () {
    final buffer = Uint8List(10000);
    for (var i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('multiblock', () async {
      final compressedData = [
        ...GZipEncoder().encode([1, 2, 3]),
        ...GZipEncoder().encode([4, 5, 6])
      ];
      final decodedData = GZipDecoderWeb().decode(compressedData, verify: true);
      compareBytes(decodedData, [1, 2, 3, 4, 5, 6]);
    });

    test('encode/decode', () {
      final compressed = GZipEncoder().encode(buffer);
      final decompressed = GZipDecoder().decode(compressed, verify: true);
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

      final zBytes = GZipDecoder().decode(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/test2.tar.gz', () {
      final b = File('test/_data/test2.tar');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/test2.tar.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decode(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/a.txt.gz', () {
      final aBytes = aTxt.codeUnits;

      final file = File('test/_data/a.txt.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decode(bytes, verify: true);
      compareBytes(zBytes, aBytes);
    });

    test('encode res/cat.jpg', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final compressed = GZipEncoder().encode(bBytes);
      final f = File('$testOutputPath/cat.jpg.gz');
      f.createSync(recursive: true);
      f.writeAsBytesSync(compressed);
    });
  });
}

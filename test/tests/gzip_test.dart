import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('gzip', () {
    List<int> buffer = List<int>(10000);
    for (int i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('encode/decode', () {
      List<int> compressed = GZipEncoder().encode(buffer);
      List<int> decompressed =
          GZipDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('decode res/cat.jpg.gz', () {
      var b = io.File(p.join(testDirPath, 'res/cat.jpg'));
      List<int> b_bytes = b.readAsBytesSync();

      var file = io.File(p.join(testDirPath, 'res/cat.jpg.gz'));
      var bytes = file.readAsBytesSync();

      var z_bytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compare_bytes(z_bytes, b_bytes);
    });

    test('decode res/test2.tar.gz', () {
      var b = io.File(p.join(testDirPath, 'res/test2.tar'));
      List<int> b_bytes = b.readAsBytesSync();

      var file = io.File(p.join(testDirPath, 'res/test2.tar.gz'));
      var bytes = file.readAsBytesSync();

      var z_bytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compare_bytes(z_bytes, b_bytes);
    });

    test('decode res/a.txt.gz', () {
      List<int> a_bytes = a_txt.codeUnits;

      var file = io.File(p.join(testDirPath, 'res/a.txt.gz'));
      var bytes = file.readAsBytesSync();

      var z_bytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compare_bytes(z_bytes, a_bytes);
    });

    test('encode res/cat.jpg', () {
      var b = io.File(p.join(testDirPath, 'res/cat.jpg'));
      List<int> b_bytes = b.readAsBytesSync();

      List<int> compressed = GZipEncoder().encode(b_bytes);
      io.File f = io.File(p.join(testDirPath, 'out/cat.jpg.gz'));
      f.createSync(recursive: true);
      f.writeAsBytesSync(compressed);
    });
  });
}

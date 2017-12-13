import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'test_utils.dart';

void main() {
  test('decode', () {
    List<int> orig = new io.File(p.join(testDirPath, 'res/bzip2/test.bz2'))
        .readAsBytesSync();

    new BZip2Decoder().decodeBytes(orig, verify: true);
  });

  test('encode', () {
    List<int> file =
        new io.File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();

    List<int> compressed = new BZip2Encoder().encode(file);

    List<int> d2 = new BZip2Decoder().decodeBytes(compressed, verify: true);

    expect(d2.length, equals(file.length));
    for (int i = 0, len = d2.length; i < len; ++i) {
      expect(d2[i], equals(file[i]));
    }
  });
}

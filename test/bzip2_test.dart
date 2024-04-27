import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('decode', () {
    final orig = io.File(p.join('test/_data/bzip2/test.bz2')).readAsBytesSync();

    BZip2Decoder().decode(orig, verify: true);
  });

  test('encode', () {
    final file = io.File(p.join('test/_data/cat.jpg')).readAsBytesSync();

    final compressed = BZip2Encoder().encode(file);

    final d2 = BZip2Decoder().decode(compressed, verify: true);

    expect(d2.length, equals(file.length));
    for (var i = 0, len = d2.length; i < len; ++i) {
      expect(d2[i], equals(file[i]));
    }
  });
}

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('decode', () {
    final orig = io.File(p.join('test/_data/bzip2/test.bz2')).readAsBytesSync();

    BZip2Decoder().decodeBytes(orig, verify: true);
  });

  test('encode', () {
    final file = io.File(p.join('test/_data/cat.jpg')).readAsBytesSync();

    final compressed = BZip2Encoder().encodeBytes(file);

    final d2 = BZip2Decoder().decodeBytes(compressed, verify: true);

    expect(d2.length, equals(file.length));
    for (var i = 0, len = d2.length; i < len; ++i) {
      expect(d2[i], equals(file[i]));
    }
  });

  test('ignores selectors past the most a block can use', () {
    // Some encoders write more than the 18002 selectors a block can use.
    // libbzip2 reads the rest and ignores them; this used to be reported as
    // a truncated stream.
    final data = Uint8List.fromList(List.generate(1000, (i) => i % 7));
    final compressed = BZip2Encoder().encodeBytes(data);

    final bits = [
      for (final byte in compressed)
        for (var i = 7; i >= 0; i--) (byte >> i) & 1
    ];
    int read(int at, int n) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        v = (v << 1) | bits[at + i];
      }
      return v;
    }

    // Stream header, block magic, block CRC, randomised bit, origPtr.
    var at = 32 + 48 + 32 + 1 + 24;
    final inUse16 = read(at, 16);
    at += 16;
    for (var i = 0; i < 16; i++) {
      if (inUse16 & (0x8000 >> i) != 0) {
        at += 16;
      }
    }
    final groups = read(at, 3);
    at += 3;
    final selectors = read(at, 15);
    expect(groups, greaterThanOrEqualTo(2));
    // Declare 18010, adding zeros, which repeat the selector before.
    const declared = 18010;
    for (var i = 0; i < 15; i++) {
      bits[at + i] = (declared >> (14 - i)) & 1;
    }
    at += 15;
    for (var i = 0; i < selectors; i++) {
      while (bits[at++] == 1) {}
    }
    bits.insertAll(at, List.filled(declared - selectors, 0));

    final bytes = Uint8List((bits.length + 7) >> 3);
    for (var i = 0; i < bits.length; i++) {
      bytes[i >> 3] |= bits[i] << (7 - (i & 7));
    }
    expect(BZip2Decoder().decodeBytes(bytes, verify: true), equals(data));
  });
}

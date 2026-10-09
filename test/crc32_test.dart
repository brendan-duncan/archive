import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  group('crc32', () {
    test('empty', () {
      final crcVal = getCrc32([]);
      expect(crcVal, 0);
    });
    test('1 byte', () {
      final crcVal = getCrc32([1]);
      expect(crcVal, 0xA505DF1B);
    });
    test('10 bytes', () {
      final crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0]);
      expect(crcVal, 0xC5F5BE65);
    });
    test('typed data takes the word at a time path', () {
      // Reference values from zlib.crc32.
      final d =
          Uint8List.fromList(List.generate(100003, (i) => (i * 31) & 0xff));
      expect(getCrc32(d), 0xac545a15);
      expect(getCrc32(List<int>.of(d)), 0xac545a15);
      // Unaligned starts, and short tails.
      expect(getCrc32(Uint8List.sublistView(d, 1)), 0x329780e3);
      expect(getCrc32(Uint8List.sublistView(d, 3, 50000)), 0x8c33daf0);
      expect(getCrc32(Uint8List.sublistView(d, 5, 37)), 0x874a17de);
      // Continued from a previous value.
      expect(getCrc32(d.sublist(50000), getCrc32(d.sublist(0, 50000))),
          0xac545a15);
    });

    test('100000 bytes', () {
      var crcVal = getCrc32([]);
      for (var i = 0; i < 10000; i++) {
        crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0], crcVal);
      }
      expect(crcVal, 0x3AC67C2B);
    });
  });
}

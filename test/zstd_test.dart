import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/zstd/xxhash64_32.dart' as xxh32;
import 'package:archive/src/codecs/zstd/xxhash64_64.dart' as xxh64;
import 'package:archive/src/codecs/zstd/zstd_bit_reader_32.dart' as br32;
import 'package:archive/src/codecs/zstd/zstd_bit_reader_64.dart' as br64;
import 'package:test/test.dart';

import '_test_util.dart';
import '_zstd_util.dart';

// The fixtures in test/_data/zstd were written by the reference zstd library,
// through Node and Python; see gen_fixtures.js there. This file reads them,
// so it runs on the VM only. zstd_web_test.dart covers the web targets.

Uint8List _fixture(String name) =>
    File('test/_data/zstd/$name').readAsBytesSync();

Uint8List _decode(String name, {List<int>? dictionary}) =>
    ZstdDecoder(dictionary: dictionary)
        .decodeBytes(_fixture(name), verify: true, throwOnError: true);

void main() {
  group('zstd', () {
    final synth300k = synth(300000, 1);

    for (final level in ['l1', 'l3', 'l19', 'lm5']) {
      test('synth.$level.zst', () {
        compareBytes(_decode('synth.$level.zst'), synth300k);
      });
    }

    test('a small window, no content size, and the window sliding', () {
      compareBytes(_decode('synth.w10.zst'), synth300k);
    });

    test('raw and RLE blocks', () {
      compareBytes(
          _decode('blocks.zst'),
          concat([
            randomBytes(5000, 8),
            List.filled(5000, 0x41),
            synth(5000, 9),
          ]));
    });

    test('RLE literals', () {
      compareBytes(_decode('rle.zst'), rleLiterals(300000, 2));
    });

    test('Huffman weights stored directly', () {
      compareBytes(_decode('nibbles.zst'), nibbles(20000, 3));
    });

    test('several frames and a skippable frame', () {
      final a = synth(1000, 4);
      compareBytes(_decode('multi.zst'), concat([a, synth(20000, 5), a]));
    });

    test('raw content dictionary', () {
      final dictionary = synth(30000, 6);
      final expected =
          concat([dictionary.sublist(5000, 25000), synth(10000, 7)]);
      compareBytes(_decode('rawdict.zst', dictionary: dictionary), expected);
    });

    test('trained dictionary', () {
      final dictionary = _fixture('fmtdict.dict');
      final expected = _fixture('fmtdict.txt');
      compareBytes(_decode('fmtdict.zst', dictionary: dictionary), expected);
      compareBytes(
          _decode('fmtdict.l19.zst', dictionary: dictionary), expected);
    });

    test('a frame that needs a dictionary is refused without it', () {
      final data = _fixture('fmtdict.zst');
      expect(
          ZstdDecoder()
              .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
          isFalse);
      expect(() => ZstdDecoder().decodeBytes(data, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      // Nor does a different dictionary stand in for it
      expect(
          () => ZstdDecoder(dictionary: synth(1000, 1))
              .decodeBytes(data, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('a malformed dictionary is an ArgumentError', () {
      final dictionary = _fixture('fmtdict.dict');
      expect(() => ZstdDecoder(dictionary: dictionary.sublist(0, 20)),
          throwsArgumentError);
    });

    test('decodeStream between files', () {
      final input = InputFileStream('test/_data/zstd/synth.w10.zst');
      final path = '$testOutputPath/synth.w10';
      final output = OutputFileStream(path);
      expect(ZstdDecoder().decodeStream(input, output, verify: true), isTrue);
      output.closeSync();
      input.closeSync();
      compareBytes(File(path).readAsBytesSync(), synth300k);
    });

    test('verify catches a damaged checksum', () {
      final data = _fixture('synth.l3.zst');
      final damaged = Uint8List.fromList(data);
      damaged[damaged.length - 1] ^= 0xff;
      // The checksum is only read when asked for
      expect(ZstdDecoder().decodeBytes(damaged).length, synth300k.length);
      expect(
          ZstdDecoder().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: true),
          isFalse);
    });

    test('maxWindowSize bounds what a frame may ask for', () {
      // The frames in synth.w10.zst have a 1 KB window
      final data = _fixture('synth.w10.zst');
      expect(
          ZstdDecoder(maxWindowSize: 1024)
              .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
          isTrue);
      expect(
          ZstdDecoder(maxWindowSize: 1023)
              .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
          isFalse);
      expect(() => ZstdDecoder(maxWindowSize: -1), throwsArgumentError);
    });

    test('bad input is refused, not thrown', () {
      for (final data in [
        <int>[],
        [1, 2, 3],
        [0x28, 0xb5, 0x2f, 0xfd],
        List.filled(100, 0x28),
      ]) {
        expect(
            ZstdDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(() => ZstdDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      }
    });

    test('every truncation is refused', () {
      // Single frames: cut at the end of a frame, a stream of several is a
      // shorter stream but a valid one.
      final dictionary = _fixture('fmtdict.dict');
      for (final name in ['fmtdict.zst', 'nibbles.zst']) {
        final data = _fixture(name);
        for (var n = 0; n < data.length; n++) {
          expect(
              ZstdDecoder(dictionary: dictionary).decodeStream(
                  InputMemoryStream(Uint8List.sublistView(data, 0, n)),
                  OutputMemoryStream(),
                  verify: true),
              isFalse,
              reason: '$name truncated to $n bytes');
        }
      }
    });

    test('damaged data is refused or decoded, never thrown', () {
      // Decoding damaged data may well succeed, with wrong output, when there
      // is no checksum to notice. What matters is that it does not throw or
      // hang.
      final rnd = Random(1);
      for (final name in ['synth.l3.zst', 'synth.l19.zst', 'blocks.zst']) {
        final data = _fixture(name);
        for (var i = 0; i < 300; i++) {
          final damaged = Uint8List.fromList(data);
          for (var j = 0, n = 1 + rnd.nextInt(4); j < n; j++) {
            damaged[rnd.nextInt(min(damaged.length, 2000))] ^=
                1 << rnd.nextInt(8);
          }
          ZstdDecoder().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: rnd.nextBool());
        }
      }
    });
  });

  group('zstd internals', () {
    // The web implementations are compiled on the VM here too, against the
    // native ones, which the fixtures check against the reference library.

    test('the 32 bit bit reader reads what the 64 bit one does', () {
      final rnd = Random(1);
      for (var t = 0; t < 5000; t++) {
        final len = 1 + rnd.nextInt(24);
        final buf = Uint8List(len + 4);
        for (var i = 0; i < buf.length; i++) {
          buf[i] = rnd.nextInt(256);
        }
        buf[len + 1] |= 1;
        final a = br32.ZstdBitReader()..init(buf, 2, len + 2);
        final b = br64.ZstdBitReader()..init(buf, 2, len + 2);
        for (var k = 0; k < 40; k++) {
          final op = rnd.nextInt(3);
          int x;
          int y;
          if (op == 0) {
            final n = rnd.nextInt(33);
            x = a.readBits(n);
            y = b.readBits(n);
          } else if (op == 1) {
            final n = rnd.nextInt(23);
            x = a.peekBits(n);
            y = b.peekBits(n);
            a.skipBits(n);
            b.skipBits(n);
          } else {
            a.refill();
            b.refill();
            final n = rnd.nextInt(br32.ZstdBitReader.bitsAfterRefill + 1);
            x = a.peekBitsFast(n);
            y = b.peekBitsFast(n);
          }
          expect(x, y, reason: 'stream $t, step $k');
          expect(a.isFinished, b.isFinished, reason: 'stream $t, step $k');
          expect(a.isOverflowed, b.isOverflowed, reason: 'stream $t, step $k');
        }
      }
    });

    test('XXH64', () {
      // The low 32 bits of XXH64 of nothing, with a seed of zero
      expect(xxh64.XxHash64().digestLow32(), 0x51D8E999);
      expect(xxh32.XxHash64().digestLow32(), 0x51D8E999);

      // The 32 bit version against the 64 bit one, over lengths that end at
      // every point of a stripe, added in pieces of every size
      final rnd = Random(3);
      final data = randomBytes(5000, 1);
      for (var len = 0; len < 300; len++) {
        final a = xxh32.XxHash64();
        final b = xxh64.XxHash64();
        var p = 0;
        while (p < len) {
          final n = min(len - p, rnd.nextInt(40));
          a.update(data, p, p + n);
          b.update(data, p, p + n);
          p += n;
        }
        expect(a.digestLow32(), b.digestLow32(), reason: 'length $len');
      }
      final a = xxh32.XxHash64()..update(data, 0, data.length);
      final b = xxh64.XxHash64()..update(data, 0, data.length);
      expect(a.digestLow32(), b.digestLow32());
    });
  });
}

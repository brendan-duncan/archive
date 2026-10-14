@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        InputFileStream,
        OutputFileStream,
        zstdDefaultLevel,
        zstdMaxLevel,
        zstdMinLevel;
import 'package:archive/src/codecs/zstd/zstd_chunked.dart';
import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd/zstd_frame_decoder.dart';
import 'package:archive/src/codecs/zstd/zstd_window.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:archive/src/util/xxh64.dart';
import 'package:test/test.dart';

import '_test_util.dart';
import '_zstd_util.dart';

// Vectors written by zstd 1.5.7. Only the compressed side is stored: each row
// carries the length and CRC-32 of what it must decode to, which is enough to
// catch any difference without keeping the originals in the repository.
const _vectors = <List<Object>>[
  ['text-empty-l1.zst', 0, 0],
  ['text-empty-l19.zst', 0, 0],
  ['text-empty-nocheck.zst', 0, 0],
  ['text-1-l1.zst', 1, 2564639436],
  ['text-1-l19.zst', 1, 2564639436],
  ['text-1-nocheck.zst', 1, 2564639436],
  ['text-7-l1.zst', 7, 82448416],
  ['text-7-l19.zst', 7, 82448416],
  ['text-7-nocheck.zst', 7, 82448416],
  ['text-8-l1.zst', 8, 4206782857],
  ['text-8-l19.zst', 8, 4206782857],
  ['text-8-nocheck.zst', 8, 4206782857],
  ['text-65-l1.zst', 65, 1524059729],
  ['text-65-l19.zst', 65, 1524059729],
  ['text-65-nocheck.zst', 65, 1524059729],
  ['text-1k-l1.zst', 1000, 2004545584],
  ['text-1k-l19.zst', 1000, 2004545584],
  ['text-1k-nocheck.zst', 1000, 2004545584],
  ['text-block-edge-l1.zst', 131073, 2188447095],
  ['text-block-edge-l19.zst', 131073, 2188447095],
  ['text-block-edge-nocheck.zst', 131073, 2188447095],
  ['text-200k-l1.zst', 200000, 3355992480],
  ['text-200k-l19.zst', 200000, 3355992480],
  ['text-200k-nocheck.zst', 200000, 3355992480],
  ['rle-1-l1.zst', 1, 476252946],
  ['rle-1-l19.zst', 1, 476252946],
  ['rle-1-nocheck.zst', 1, 476252946],
  ['rle-1k-l1.zst', 1000, 2810990746],
  ['rle-1k-l19.zst', 1000, 2810990746],
  ['rle-1k-nocheck.zst', 1000, 2810990746],
  ['rle-200k-l1.zst', 200000, 1803209211],
  ['rle-200k-l19.zst', 200000, 1803209211],
  ['rle-200k-nocheck.zst', 200000, 1803209211],
  ['random-1-l1.zst', 1, 3624026538],
  ['random-1-l19.zst', 1, 3624026538],
  ['random-1-nocheck.zst', 1, 3624026538],
  ['random-100-l1.zst', 100, 917727960],
  ['random-100-l19.zst', 100, 917727960],
  ['random-100-nocheck.zst', 100, 917727960],
  ['random-4k-l1.zst', 4096, 1699625419],
  ['random-4k-l19.zst', 4096, 1699625419],
  ['random-4k-nocheck.zst', 4096, 1699625419],
  ['mix-1k-l1.zst', 1000, 1204304730],
  ['mix-1k-l19.zst', 1000, 1204304730],
  ['mix-1k-nocheck.zst', 1000, 1204304730],
  ['mix-70k-l1.zst', 70000, 1811542865],
  ['mix-70k-l19.zst', 70000, 1811542865],
  ['mix-70k-nocheck.zst', 70000, 1811542865],
  ['mix-200k-l1.zst', 200000, 1110379402],
  ['mix-200k-l19.zst', 200000, 1110379402],
  ['mix-200k-nocheck.zst', 200000, 1110379402],
  ['multi-frame.zst', 85097, 1639112962],
  ['skippable-lead.zst', 200000, 1110379402],
  ['sources-slice-l3.zst', 400000, 948042585],
  ['sources-slice-l19.zst', 400000, 948042585],
  ['domains-slice-l19.zst', 400000, 1576664692],
];

void main() {
  final directory = Directory('test/_data/zstd');

  group('zstd', () {
    for (final vector in _vectors) {
      final name = vector[0] as String;
      final length = vector[1] as int;
      final crc = vector[2] as int;
      final bytes = File('${directory.path}/$name').readAsBytesSync();

      test('$name decodes in one piece', () {
        final decoded =
            ZstdDecoder().decodeBytes(bytes, verify: true, throwOnError: true);
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });

      test('$name decodes through stream', () {
        final output = OutputMemoryStream();
        final ok = ZstdDecoder().decodeStream(InputMemoryStream(bytes), output,
            verify: true, throwOnError: true);
        expect(ok, isTrue);
        final decoded = output.getBytes();
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });

      test('$name reports correct content size', () {
        final size = ZstdDecoder().uncompressedSize(bytes);
        if (size != null) {
          expect(size, length);
        }
      });
    }

    test('truncated frame throws ArchiveException', () {
      final bytes = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
      for (final cut in [4, 8, 20, bytes.length ~/ 2, bytes.length - 1]) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(bytes, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });

    test('corrupt byte throws on checksum mismatch', () {
      final bytes = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
      var caught = 0;
      for (var at = 20; at < bytes.length - 4; at += 997) {
        final broken = Uint8List.fromList(bytes);
        broken[at] ^= 0x40;
        final Uint8List decoded;
        try {
          decoded = ZstdDecoder()
              .decodeBytes(broken, verify: true, throwOnError: true);
        } catch (_) {
          caught++;
          continue;
        }
        expect(getCrc32(decoded), 1811542865,
            reason: 'byte $at changed the output without being reported');
      }
      expect(caught, greaterThan(0));
    });

    test('input that is not zstd throws', () {
      expect(
          () => ZstdDecoder().decodeBytes(
              Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          ZstdDecoder().decodeBytes(Uint8List.fromList([1, 2, 3, 4])), isEmpty);
    });

    test('window above limit throws', () {
      final bytes =
          File('${directory.path}/mix-200k-l19.zst').readAsBytesSync();
      expect(
          () => ZstdDecoder(maxWindowSize: 1024).decodeBytes(bytes),
          throwsA(isA<ArchiveLimitException>()));
    });

    test('small decodeBytes result is not view of larger output buffer', () {
      final data = Uint8List.fromList('alpha beta gamma'.codeUnits);
      final sized = ZstdEncoder().encodeBytes(data);
      final unsized = const ZstdEncoderConverter().convert(data);
      expect(ZstdDecoder().uncompressedSize(sized), data.length);
      expect(ZstdDecoder().uncompressedSize(unsized), isNull);
      for (final (name, frames) in [
        ('sized', sized),
        ('unsized', unsized),
        ('two frames', Uint8List.fromList([...sized, ...sized])),
      ]) {
        final out = ZstdDecoder().decodeBytes(frames);
        expect(out.length, name == 'two frames' ? 32 : 16, reason: name);
        expect(out.buffer.lengthInBytes, out.length, reason: name);
      }
    });
  });

  // A frame is rejected by whichever part of it stops making sense first, and
  // each of those parts reports on its own. A checksum catches what gets that
  // far, so a corruption has to be aimed to reach the tables at all
  group('zstd rejects', () {
    final frame = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
    final short = File('${directory.path}/text-1k-l19.zst').readAsBytesSync();

    Uint8List broken(Uint8List from, int at, int value) =>
        Uint8List.fromList(from)..[at] = value;

    void reject(Uint8List bytes, String reason) {
      expect(() => ZstdDecoder().decodeBytes(bytes, throwOnError: true),
          throwsA(isA<ArchiveException>()),
          reason: reason);
    }

    test('bytes after zero sequence count in block', () {
      const valid = [40, 181, 47, 253, 0, 0, 29, 0, 0, 8, 97, 0];
      final trailing =
          Uint8List.fromList([40, 181, 47, 253, 0, 0, 37, 0, 0, 8, 97, 0, 153]);
      expect(ZstdDecoder().decodeBytes(valid, throwOnError: true), [97]);
      reject(trailing, 'the zero sequence count must end the block');
    });

    test('frame truncated at any length', () {
      for (var cut = 1; cut < frame.length; cut++) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(frame, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });

    test('frame truncated inside first block', () {
      for (var cut = 1; cut < short.length; cut++) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(short, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });

    test('every changed frame byte throws or decodes same', () {
      final whole =
          ZstdDecoder().decodeBytes(short, verify: true, throwOnError: true);
      final crc = getCrc32(whole);
      for (var at = 4; at < short.length; at++) {
        for (final mask in [0x01, 0x55, 0x80]) {
          final bytes = Uint8List.fromList(short);
          bytes[at] ^= mask;
          Uint8List? decoded;
          try {
            decoded = ZstdDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true);
          } catch (_) {
            continue;
          }
          expect(getCrc32(decoded), crc,
              reason: 'byte $at with $mask changed the output silently');
        }
      }
    });

    // Block type three is reserved, and the header is the three bytes after
    // the frame header, which for this file is five bytes long
    test('reserved block type', () {
      final header = _firstBlockAt(short);
      reject(broken(short, header, short[header] | 6), 'reserved block type');
    });

    test('block larger than maximum block size', () {
      final header = _firstBlockAt(short);
      final bytes = Uint8List.fromList(short);
      // Size sits in the top twenty one bits of the three byte header
      bytes[header] |= 0xf8;
      bytes[header + 1] = 0xff;
      bytes[header + 2] = 0xff;
      reject(bytes, 'block larger than the limit');
    });

    test('literals section larger than block', () {
      final at = _firstBlockAt(short) + 3;
      final bytes = Uint8List.fromList(short);
      // Type two, size format three, so the header is five bytes wide
      bytes[at] = 0x0e;
      bytes[at + 1] = 0xff;
      bytes[at + 2] = 0xff;
      bytes[at + 3] = 0xff;
      bytes[at + 4] = 0xff;
      reject(bytes, 'literals larger than a block');
    });

    test('treeless literals in first block', () {
      final at = _firstBlockAt(short) + 3;
      // Type three reuses the tree of an earlier block, and there is none
      reject(
          broken(short, at, (short[at] & ~3) | 3), 'treeless without a tree');
    });

    test('empty archive', () {
      expect(() => ZstdDecoder().decodeBytes(Uint8List(0), throwOnError: true),
          throwsA(isA<ArchiveException>()));
      final out = OutputMemoryStream();
      expect(
          () => ZstdDecoder().decodeStream(InputMemoryStream(Uint8List(0)), out,
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('skippable frame running past input end', () {
      final bytes = Uint8List.fromList(
          [0x50, 0x2a, 0x4d, 0x18, 0xff, 0xff, 0xff, 0x7f, 1, 2, 3]);
      reject(bytes, 'skippable frame is truncated');
    });

    test('frame header truncated inside content size', () {
      reject(Uint8List.fromList([0x28, 0xb5, 0x2f, 0xfd, 0xa0]),
          'content size is truncated');
    });

    // The tables of a block are read before anything is written, so a change
    // there is reported by whichever table stops making sense, not by the
    // checksum. The first few hundred bytes of a block are those tables
    test('every flipped bit in block tables', () {
      final whole =
          ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true);
      final crc = getCrc32(whole);
      final from = _firstBlockAt(frame) + 3;
      final to = from + 400 < frame.length ? from + 400 : frame.length;
      for (var at = from; at < to; at++) {
        for (var bit = 0; bit < 8; bit++) {
          final bytes = Uint8List.fromList(frame);
          bytes[at] ^= 1 << bit;
          Uint8List? decoded;
          try {
            decoded = ZstdDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true);
          } catch (_) {
            continue;
          }
          expect(getCrc32(decoded), crc,
              reason: 'bit $bit of byte $at changed the output silently');
        }
      }
    });
  });

  group('zstd verify and throwOnError', () {
    final data = Uint8List.fromList(
        List.generate(300000, (i) => (i * 7 + (i >> 9)) % 251));
    final whole = ZstdEncoder().encodeBytes(data, checksum: true);
    bool decode(Uint8List bytes, bool verify, bool throwOnError) =>
        ZstdDecoder().decodeStream(
            InputMemoryStream(bytes), OutputMemoryStream(),
            verify: verify, throwOnError: throwOnError);

    test('wrong checksum throws only with verify and throwOnError', () async {
      final bad = Uint8List.fromList(whole);
      bad[bad.length - 1] ^= 1;
      expect(decode(bad, false, false), isTrue);
      expect(decode(bad, false, true), isTrue);
      expect(decode(bad, true, false), isFalse);
      expect(() => decode(bad, true, true),
          throwsA(isA<ArchiveChecksumException>()));
      await expectLater(
          Stream<List<int>>.value(bad).transform(const ZstdCodec().decoder),
          emitsThrough(emitsError(isA<ArchiveChecksumException>())));
    });

    test('truncated or foreign data throws with verify or throwOnError', () {
      for (final bad in [
        Uint8List.sublistView(whole, 0, whole.length ~/ 2),
        Uint8List.fromList(List.filled(40, 7)),
      ]) {
        expect(decode(bad, false, false), isFalse);
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => decode(bad, verify, throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))),
              reason: 'verify $verify, throwOnError $throwOnError');
        }
      }
    });
  });

  group('zstd window over concatenated frames', () {
    final source = Uint8List.fromList(
        List.generate(32 << 10, (i) => (i * 7 + (i >> 9)) & 255));
    final frame = _rawWindowFrame(source);
    final prefix = Uint8List.fromList([1, 2, 3]);
    final first = ZstdEncoder().encodeBytes(prefix);

    test('decoding window stays within window size while writing blocks', () {
      final header = readFrameHeader(frame, 4, frame.length, 1024);
      final sink = OutputMemoryStream();
      final window = ZstdWindow(header.windowSize, output: sink);
      ZstdFrameDecoder().decodeBlocks(
          frame, 4 + header.size, frame.length, window, header, true, null);
      expect(window.capacity,
          lessThanOrEqualTo(header.windowSize + 2 * header.blockReserve));
      window.finish();
      expect(sink.getBytes(), source);
    });

    test('sequences past the block are rejected before they are copied', () {
      const count = 40;
      const body = 6 + count * 20 ~/ 8 + 1;
      const head = body << 3 | 5;
      final bad = Uint8List.fromList([
        ...[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00],
        ...[0x00, 0x20, 0x00],
        ...List.filled(1024, 0x61),
        ...[head & 255, head >> 8, 0],
        ...[0x00, count, 0x54, 0, 4, 52],
        ...Uint8List(count * 20 ~/ 8),
        1,
      ]);
      final header = readFrameHeader(bad, 4, bad.length, 1024);
      final window = ZstdWindow(header.windowSize)..reserve(4 << 20);
      window.buffer.fillRange(0, window.buffer.length, 0xee);
      expect(
          () => ZstdFrameDecoder().decodeBlocks(
              bad, 4 + header.size, bad.length, window, header, true, null),
          throwsA(isA<ArchiveException>()));
      expect(
          window.buffer
              .indexWhere((b) => b != 0xee, 1024 + header.blockReserve),
          -1);
    });

    test('concatenated frames keep output correct across window wraps', () {
      final joined = Uint8List.fromList([...first, ...frame, ...first]);
      expect(
          ZstdDecoder().decodeBytes(joined, verify: true, throwOnError: true),
          [...prefix, ...source, ...prefix]);
    });

    for (final failure in ['checksum', 'block']) {
      test('late $failure failure returns every decoded block', () {
        final broken = Uint8List.fromList(frame);
        if (failure == 'checksum') {
          broken[broken.length - 1] ^= 1;
        } else {
          broken[6 + 31 * 1027] |= 6;
        }
        final joined = Uint8List.fromList([...first, ...broken]);
        final decoded = failure == 'checksum'
            ? source
            : Uint8List.sublistView(source, 0, 31 * 1024);
        expect(ZstdDecoder().decodeBytes(joined), [...prefix, ...decoded]);
        expect(ZstdDecoder().decodeBytes(broken), decoded);
        for (final input in [joined, broken]) {
          final out = OutputMemoryStream();
          expect(
              ZstdDecoder()
                  .decodeStream(InputMemoryStream(input), out, verify: true),
              isFalse);
          expect(out.getBytes(), [if (input == joined) ...prefix, ...decoded]);
        }
        final lazy =
            ZstdDecoder().decodeLazy(InputMemoryStream(broken), verify: true);
        expect(lazy.readBytes(decoded.length).toUint8List(), decoded);
        expect(() => lazy.readByte(), throwsA(isA<ArchiveException>()));
        if (failure == 'block') {
          final over = Uint8List.fromList([
            0x28,
            0xb5,
            0x2f,
            0xfd,
            0x60,
            0xdc,
            0x04,
            0x00,
            0x20,
            0x00,
            ...source.sublist(0, 1024),
            0x01,
            0x20,
            0x00,
            ...source.sublist(1024, 2048),
          ]);
          final out = OutputMemoryStream();
          expect(ZstdDecoder().decodeStream(InputMemoryStream(over), out),
              isFalse);
          expect(out.getBytes(), source.sublist(0, 1024));
          expect(ZstdDecoder().decodeBytes(over), source.sublist(0, 1024));
        }
        expect(
            () => ZstdDecoder()
                .decodeBytes(joined, verify: true, throwOnError: true),
            throwsA(failure == 'checksum'
                ? isA<ArchiveChecksumException>()
                : isA<ArchiveException>()));
      });
    }

    test('cut second frame returns every decoded block', () {
      final joined = Uint8List.fromList(
          [...first, ...frame.sublist(0, 6 + 10 * 1027 + 500)]);
      final decoded = [...prefix, ...source.sublist(0, 10 * 1024)];
      final out = OutputMemoryStream();
      expect(
          ZstdDecoder().decodeStream(InputMemoryStream(joined), out), isFalse);
      expect(out.getBytes(), decoded);
      expect(
          ZstdDecoder().decodeBytes(joined, maxOutputSize: 1 << 20), decoded);
      expect(ZstdDecoder().decodeBytes(joined), decoded);
    });
  });

  group('zstd window wrap', () {
    final source = Uint8List(3 << 20);
    for (var at = 0; at < source.length; at++) {
      source[at] = 0x20 + ((at * 7 + (at >> 9)) % 90);
    }

    for (final level in [1, 3, 6]) {
      test('level $level decodes back through smaller window', () {
        final encoded = ZstdEncoder(level: level).encodeBytes(source);
        final out = OutputMemoryStream();
        final ok = ZstdDecoder().decodeStream(InputMemoryStream(encoded), out,
            verify: true, throwOnError: true);
        expect(ok, isTrue);
        final decoded = out.getBytes();
        expect(decoded.length, source.length);
        expect(getCrc32(decoded), getCrc32(source));
      });
    }

    test('frame with dictionary wraps window same way', () {
      final dictionary = ZstdDictionary(Uint8List.fromList(
          List.generate(1 << 16, (i) => 0x20 + (i * 11 % 90))));
      final encoded =
          ZstdEncoder.withDictionary(dictionary, level: 3).encodeBytes(source);
      final out = OutputMemoryStream();
      ZstdDecoder.withDictionary(dictionary).decodeStream(
          InputMemoryStream(encoded), out,
          verify: true, throwOnError: true);
      expect(getCrc32(out.getBytes()), getCrc32(source));
    });
  });

  group('zstd', () {
    final synth300k = synth(300000, 1);

    test('maxOutputSize stops at the first block over the limit', () {
      final header = (131072 << 3) | 2;
      final frame = Uint8List.fromList([
        0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x88, //
        header & 0xff, header >> 8 & 0xff, header >> 16, 0x61,
        0x07, 0x00, 0x00,
      ]);
      final limit = throwsA(isA<ArchiveException>().having(
          (e) => e.message, 'message', contains('larger than the 1024')));
      expect(
          () => ZstdDecoder().decodeBytes(frame, maxOutputSize: 1024), limit);
      expect(
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(frame), OutputMemoryStream(),
              maxOutputSize: 1024),
          limit);
    });

    test('a declared content size allocates at most the preallocation cap', () {
      // 2^44 bytes declared, a 128 KB window, then 1 MB of one byte RLE
      // blocks, which could decode to 43 GB if every block were full
      final frame = BytesBuilder()
        ..add([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0x38])
        ..add(Uint8List(8)
          ..buffer.asByteData().setUint64(0, 1 << 44, Endian.little));
      for (var i = 0; i < 262143; i++) {
        frame.add(const [0x0a, 0x00, 0x00, 0x61]);
      }
      frame.add(const [0x0b, 0x00, 0x00, 0x61]);
      final bytes = frame.takeBytes();
      expect(ZstdDecoder().decodeBytes(bytes), List.filled(262144, 0x61));
      expect(() => ZstdDecoder().decodeBytes(bytes, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

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

    // Dictionary bytes come from a file and can be damaged like any archive,
    // so malformed dictionary throws ArchiveException, not ArgumentError
    test('a malformed dictionary is an ArchiveException', () {
      final dictionary = _fixture('fmtdict.dict');
      expect(() => ZstdDecoder(dictionary: dictionary.sublist(0, 20)),
          throwsA(isA<ArchiveException>()));
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
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
    });

    test('maxWindowSize bounds what a frame may ask for', () {
      // The frames in synth.w10.zst have a 1 KB window
      final data = _fixture('synth.w10.zst');
      expect(
          ZstdDecoder(maxWindowSize: 1024)
              .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
          isTrue);
      expect(() => ZstdDecoder(maxWindowSize: 1023), throwsArgumentError);
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
      final dictionary = ZstdDictionary(_fixture('fmtdict.dict'));
      for (final name in ['fmtdict.zst', 'nibbles.zst']) {
        final data = _fixture(name);
        for (var n = 0; n < data.length; n++) {
          expect(
              () => ZstdDecoder.withDictionary(dictionary).decodeStream(
                  InputMemoryStream(Uint8List.sublistView(data, 0, n)),
                  OutputMemoryStream(),
                  verify: true,
                  throwOnError: true),
              throwsA(isA<ArchiveException>()),
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
          final verify = rnd.nextBool();
          try {
            ZstdDecoder().decodeStream(
                InputMemoryStream(damaged), OutputMemoryStream(),
                verify: verify);
          } on ArchiveException {
            expect(verify, isTrue);
          }
        }
      }
    });

    test('refuses a content size that overflows', () {
      // Eight byte content size with the top bit set.
      final frame = [
        0x28,
        0xb5,
        0x2f,
        0xfd,
        0xc0,
        0x00,
        ...List.filled(8, 0xff)
      ];
      expect(
          ZstdDecoder()
              .decodeStream(InputMemoryStream(frame), OutputMemoryStream()),
          isFalse);
    });

    test('stops at the content size, not after the frame', () async {
      const magic = [0x28, 0xb5, 0x2f, 0xfd];
      // A 64 KB window, kept for the frame that follows.
      final first = [...magic, 0x00, 0x30, 0x03, 0x00, 0x08, 0x61];
      // A 1 KB window and a content size of 256, then a hundred 1 KB RLE
      // blocks.
      final second = [
        ...magic,
        0x40,
        0x00,
        0x00,
        0x00,
        for (var i = 0; i < 99; i++) ...[0x02, 0x20, 0x00, 0x62],
        0x03,
        0x20,
        0x00,
        0x62,
      ];
      final output = OutputMemoryStream();
      expect(
          ZstdDecoder()
              .decodeStream(InputMemoryStream([...first, ...second]), output),
          isFalse);
      expect(output.length, lessThanOrEqualTo(65536 + 1024));

      var converted = 0;
      await expectLater(
          Stream.value([...first, ...second])
              .transform(zstdCodec.decoder)
              .forEach((piece) => converted += piece.length),
          throwsA(isA<ArchiveException>()));
      expect(converted, lessThanOrEqualTo(65536 + 1024));
    });

    test('a header with no blocks after it is refused', () {
      // A 128 MB window and a content size of 192 MB, with no blocks.
      final frame = [
        0x28,
        0xb5,
        0x2f,
        0xfd,
        0x80,
        0x88,
        0xff,
        0xff,
        0xff,
        0x0b
      ];
      final output = OutputMemoryStream();
      expect(ZstdDecoder().decodeStream(InputMemoryStream(frame), output),
          isFalse);
      expect(ZstdDecoder().decodeBytes(frame), isEmpty);
    });
  });

  group('zstd encoder', () {
    Uint8List roundTrip(List<int> data,
        {int level = 3, bool checksum = false}) {
      final z =
          ZstdEncoder().encodeBytes(data, level: level, checksum: checksum);
      return ZstdDecoder().decodeBytes(z, verify: true, throwOnError: true);
    }

    final sample = synth(300000, 21);

    test('every level', () {
      for (var level = -7; level <= zstdMaxLevel; level++) {
        compareBytes(roundTrip(sample, level: level), sample);
      }
    });

    test('higher levels compress better', () {
      // This library's own source, as real text that is always at hand
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final text = concat([for (final f in files) f.readAsBytesSync()]);
      var previous = text.length;
      for (final level in [-5, 1, 3, 5, 9, 19]) {
        final z = ZstdEncoder().encodeBytes(text, level: level);
        expect(z.length, lessThan(previous), reason: 'level $level');
        compareBytes(ZstdDecoder().decodeBytes(z), text);
        previous = z.length;
      }
    });

    test('all sorts of input', () {
      for (final data in <List<int>>[
        [],
        [7],
        [1, 2],
        List.filled(100000, 42),
        randomBytes(50000, 3),
        rleLiterals(200000, 4),
        nibbles(30000, 5),
        concat(
            [randomBytes(200000, 6), synth(200000, 7), List.filled(300000, 0)]),
      ]) {
        for (final level in [-3, 1, 3, 7, 16]) {
          compareBytes(roundTrip(data, level: level, checksum: true), data);
        }
      }
    });

    test('checksum', () {
      final plain = ZstdEncoder().encodeBytes(sample, checksum: false);
      expect(ZstdEncoder().encodeBytes(sample), plain);
      final checked = ZstdEncoder().encodeBytes(sample, checksum: true);
      expect(checked.length, plain.length + 4);
      final damaged = Uint8List.fromList(checked);
      damaged[damaged.length - 1] ^= 1;
      expect(
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
    });

    test('encodeStream between files matches encodeBytes', () {
      // Larger than the window and its buffer, so the file is read in pieces
      // and the match finders' tables slide along with it.
      final data = synth(3000000, 8);
      final inPath = '$testOutputPath/zstd_encode_in.bin';
      File(inPath).writeAsBytesSync(data);
      for (final level in [1, 3, 5]) {
        final outPath = '$testOutputPath/zstd_encode_out.$level.zst';
        final input = InputFileStream(inPath);
        final output = OutputFileStream(outPath);
        ZstdEncoder().encodeStream(input, output, level: level, checksum: true);
        output.closeSync();
        input.closeSync();
        final fromFile = File(outPath).readAsBytesSync();
        compareBytes(fromFile,
            ZstdEncoder().encodeBytes(data, level: level, checksum: true));
        compareBytes(ZstdDecoder().decodeBytes(fromFile, verify: true), data);
      }
    });

    test('levels out of range are refused', () {
      expect(ZstdEncoder().encodeBytes(sample, level: zstdMaxLevel + 1),
          ZstdEncoder().encodeBytes(sample, level: zstdMaxLevel));
      expect(ZstdEncoder().encodeBytes(sample, level: zstdMinLevel - 1),
          ZstdEncoder().encodeBytes(sample, level: zstdMinLevel));
      // Zero is the default level
      expect(ZstdEncoder().encodeBytes(sample, level: 0),
          ZstdEncoder().encodeBytes(sample, level: zstdDefaultLevel));
    });
  });

  group('zstd internals', () {
    test('XXH64', () {
      // The low 32 bits of XXH64 of nothing, with a seed of zero
      expect(Xxh64(0).digestLow, 0x51D8E999);
    });
  });
}

Uint8List _fixture(String name) =>
    File('test/_data/zstd/$name').readAsBytesSync();

Uint8List _decode(String name, {List<int>? dictionary}) =>
    ZstdDecoder(dictionary: dictionary)
        .decodeBytes(_fixture(name), verify: true, throwOnError: true);

Uint8List _rawWindowFrame(Uint8List source) {
  final bytes = BytesBuilder()..add([0x28, 0xb5, 0x2f, 0xfd, 4, 0]);
  for (var at = 0; at < source.length; at += 1024) {
    final end = at + 1024 < source.length ? at + 1024 : source.length;
    final header = ((end - at) << 3) | (end == source.length ? 1 : 0);
    bytes.add([header & 255, (header >> 8) & 255, header >> 16]);
    bytes.add(Uint8List.sublistView(source, at, end));
  }
  final hash = Xxh64()..update(source, 0, source.length);
  final checksum = ByteData(4)..setUint32(0, hash.digestLow, Endian.little);
  bytes.add(checksum.buffer.asUint8List());
  return bytes.takeBytes();
}

/// Where the first block header sits: the magic, the descriptor, and whatever
/// widths the descriptor asks of the window, the dictionary id and the size
int _firstBlockAt(Uint8List frame) {
  final descriptor = frame[4];
  final sizeFlag = descriptor >> 6;
  final single = (descriptor & 0x20) != 0;
  final idBytes = const [0, 1, 2, 4][descriptor & 3];
  final sizeBytes = sizeFlag == 0 ? (single ? 1 : 0) : 1 << sizeFlag;
  return 5 + (single ? 0 : 1) + idBytes + sizeBytes;
}

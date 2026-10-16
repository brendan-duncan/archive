import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

    test(
        'GZipEncoderWeb into big-endian output decodes back and keeps byte order',
        () {
      final origData = [1, 2, 3, 4, 5, 6];
      final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
      GZipEncoderWeb().encodeStream(InputMemoryStream(origData), output);
      final uncompressed =
          GZipDecoder().decodeBytes(output.getBytes(), verify: true);
      compareBytes(uncompressed, origData);
      expect(output.byteOrder, ByteOrder.bigEndian);
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

    test('decode res/cat.jpg.gz', testOn: 'vm', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/cat.jpg.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/test2.tar.gz', testOn: 'vm', () {
      final b = File('test/_data/test2.tar');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/test2.tar.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/a.txt.gz', testOn: 'vm', () {
      final aBytes = aTxt.codeUnits;

      final file = File('test/_data/a.txt.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, aBytes);
    });

    test('encode res/cat.jpg', testOn: 'vm', () {
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

      test('a member cut off inside its header', () {
        // 10 header + 2 deflate + 8 trailer is the least a member can be;
        // below that the last eight bytes are header, not the trailer
        for (var n = 1; n < 20; ++n) {
          final short = Uint8List.sublistView(whole, 0, n);
          decode(GZipDecoder(), short, ok: false);
          decodeWeb(short, ok: false);
        }
        // The bound is not off by one: an empty file encodes to exactly 20
        final empty = Uint8List.fromList(GZipEncoder().encodeBytes(<int>[]));
        expect(empty.length, equals(20));
        expect(decode(GZipDecoder(), empty, ok: true), 0);
        expect(decodeWeb(empty, ok: true), 0);
      });

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

    group('verify and throwOnError', () {
      final data = Uint8List(300000);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 7 + (i >> 9)) % 251;
      }
      final gzip = Uint8List.fromList(GZipEncoder().encodeBytes(data));
      final zlib = Uint8List.fromList(ZLibEncoder().encodeBytes(data));
      final decoders = {
        'gzip': (Uint8List b, bool v, bool t) => const GZipDecoder()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'gzip web': (Uint8List b, bool v, bool t) => const GZipDecoderWeb()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'zlib': (Uint8List b, bool v, bool t) => const ZLibDecoder()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'zlib web': (Uint8List b, bool v, bool t) => const ZLibDecoderWeb()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
      };
      Uint8List of(String name) => name.startsWith('gzip') ? gzip : zlib;

      for (final web in [false, true]) {
        test(
            'verify of 2 members works with sink output that cannot be read back, web $web',
            () {
          final joined = Uint8List.fromList([...gzip, ...gzip]);
          List<List<int>>? chunks;
          final output = SinkOutputStream(
              ChunkedConversionSink<List<int>>.withCallback(
                  (all) => chunks = all));
          output.writeBytes([1, 2, 3]);
          final input = InputMemoryStream([4, 5, ...joined, 6, 7])
              .subset(position: 1, length: joined.length + 1)
            ..skip(1);
          final ok = web
              ? const GZipDecoderWeb().decodeStream(input, output, verify: true)
              : const GZipDecoder().decodeStream(input, output, verify: true);
          expect(ok, isTrue);
          output.sink.close();
          expect(chunks!.expand((chunk) => chunk), [1, 2, 3, ...data, ...data]);
        });

        test('verify of 2 members finishes when onProgress throws, web $web',
            () {
          final error = StateError('progress callback failed');
          final input = InputMemoryStream([4, 5, ...gzip, ...gzip])..skip(2);
          final output = ProgressOutputStream(
              OutputMemoryStream(), (_) => throw error,
              interval: 1);
          final errors = <Object>[];
          late bool ok;
          runZonedGuarded(() {
            ok = web
                ? const GZipDecoderWeb()
                    .decodeStream(input, output, verify: true)
                : const GZipDecoder().decodeStream(input, output, verify: true);
          }, (thrown, _) => errors.add(thrown));
          expect(ok, isTrue);
          expect(errors, isNotEmpty);
          expect(errors, everyElement(same(error)));
        });
      }

      for (final stream in [false, true]) {
        test(
            'native gzip with verify checks optional header CRC, stream $stream',
            () {
          final header = gzip.sublist(0, 10)..[3] |= 2;
          final crc = getCrc32(header);
          final member = Uint8List.fromList([
            ...header,
            crc & 255,
            (crc >> 8) & 255,
            ...gzip.sublist(10),
          ]);
          Object decode(List<int> bytes,
                  {bool verify = false, bool throwOnError = false}) =>
              stream
                  ? const GZipDecoder().decodeStream(
                      InputMemoryStream(bytes), OutputMemoryStream(),
                      verify: verify, throwOnError: throwOnError)
                  : const GZipDecoder().decodeBytes(bytes,
                      verify: verify, throwOnError: throwOnError);
          expect(decode(member, verify: true), stream ? isTrue : equals(data));
          for (final byte in [3, 10, 11]) {
            final bad = Uint8List.fromList(member);
            bad[byte] ^= byte == 3 ? 0x80 : 1;
            expect(() => decode(bad, verify: true, throwOnError: true),
                throwsA(isA<ArchiveException>()));
            expect(() => decode(bad, throwOnError: true),
                throwsA(isA<ArchiveException>()));
          }
        });

        test('web gzip with verify checks optional header CRC, stream $stream',
            () {
          final header = gzip.sublist(0, 10)..[3] |= 2;
          final crc = getCrc32(header);
          final member = Uint8List.fromList([
            ...header,
            crc & 255,
            (crc >> 8) & 255,
            ...gzip.sublist(10),
          ]);
          Object decode(List<int> bytes,
                  {bool verify = false, bool throwOnError = false}) =>
              stream
                  ? const GZipDecoderWeb().decodeStream(
                      InputMemoryStream(bytes), OutputMemoryStream(),
                      verify: verify, throwOnError: throwOnError)
                  : const GZipDecoderWeb().decodeBytes(bytes,
                      verify: verify, throwOnError: throwOnError);
          expect(decode(member, verify: true), stream ? isTrue : equals(data));
          for (final byte in [3, 10, 11]) {
            final bad = Uint8List.fromList(member);
            bad[byte] ^= byte == 3 ? 0x80 : 1;
            expect(() => decode(bad, verify: true, throwOnError: true),
                throwsA(isA<ArchiveException>()),
                reason: 'header byte $byte');
            expect(() => decode(bad, throwOnError: true),
                throwsA(isA<ArchiveException>()),
                reason: 'header byte $byte');
          }
        });

        test(
            'verify and throwOnError reject damaged header of later gzip member, stream $stream',
            () {
          for (final byte in [0, 1, 2]) {
            final bad = Uint8List.fromList([...gzip, ...gzip]);
            bad[gzip.length + byte] ^= 1;
            for (final (verify, throwOnError) in [
              (true, true),
              (false, true)
            ]) {
              expect(
                  () => stream
                      ? const GZipDecoder().decodeStream(
                          InputMemoryStream(bad), OutputMemoryStream(),
                          verify: verify, throwOnError: throwOnError)
                      : const GZipDecoder().decodeBytes(bad,
                          verify: verify, throwOnError: throwOnError),
                  throwsA(isA<ArchiveException>()),
                  reason: 'header byte $byte, verify $verify');
            }
          }
        });

        test(
            'verify checks CRC of every concatenated gzip member, stream $stream',
            () {
          final joined = Uint8List.fromList([...gzip, ...gzip, ...gzip]);
          Object decode(List<int> bytes,
              {bool verify = false, bool throwOnError = false}) {
            if (stream) {
              return const GZipDecoder().decodeStream(
                  InputMemoryStream(bytes), OutputMemoryStream(),
                  verify: verify, throwOnError: throwOnError);
            }
            return const GZipDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError);
          }

          final expected =
              stream ? isTrue : equals([...data, ...data, ...data]);
          expect(decode(joined, verify: true), expected);
          for (var member = 0; member < 3; member++) {
            for (var byte = 0; byte < 8; byte++) {
              final bad = Uint8List.fromList(joined);
              bad[(member + 1) * gzip.length - 8 + byte] ^= 1;
              expect(() => decode(bad, verify: true, throwOnError: true),
                  throwsA(isA<ArchiveException>()),
                  reason: 'member $member, trailer byte $byte');
              if (byte < 4 && member == 2) {
                expect(decode(bad, throwOnError: true), expected);
              }
            }
          }
        });
      }

      for (final MapEntry(key: name, value: decode) in decoders.entries) {
        test('$name: complete stream passes verify', () {
          expect(decode(of(name), true, false), isTrue);
        });

        test('$name: empty input throws with throwOnError', () {
          expect(decode(Uint8List(0), false, false), isFalse);
          expect(decode(Uint8List(0), true, false), isFalse);
          for (final (v, t) in [(true, true), (false, true)]) {
            expect(() => decode(Uint8List(0), v, t),
                throwsA(isA<ArchiveException>()),
                reason: 'verify $v, throwOnError $t');
          }
        });

        test('$name: wrong checksum throws only with verify and throwOnError',
            () {
          final bad = Uint8List.fromList(of(name));
          bad[bad.length - (name.startsWith('gzip') ? 8 : 1)] ^= 1;
          expect(decode(bad, false, false), isTrue);
          expect(decode(bad, false, true), isTrue);
          expect(decode(bad, true, false), isFalse);
          expect(() => decode(bad, true, true),
              throwsA(isA<ArchiveChecksumException>()));
        });

        test('$name: truncated or foreign data throws with throwOnError',
            testOn: 'vm', () {
          final whole = of(name);
          final cut = Uint8List.sublistView(whole, 0, whole.length ~/ 2);
          if (name == 'zlib') {
            expect(decode(cut, false, true), isTrue);
            expect(decode(cut, true, false), isFalse);
            expect(
                () => decode(cut, true, true),
                throwsA(allOf(isA<ArchiveException>(),
                    isNot(isA<ArchiveChecksumException>()))));
          }
          for (final bad in [
            if (name != 'zlib') cut,
            Uint8List.fromList(List.filled(40, 7)),
          ]) {
            expect(decode(bad, false, false), isFalse);
            expect(decode(bad, true, false), isFalse);
            for (final (v, t) in [(true, true), (false, true)]) {
              expect(
                  () => decode(bad, v, t),
                  throwsA(allOf(isA<ArchiveException>(),
                      isNot(isA<ArchiveChecksumException>()))),
                  reason: 'verify $v, throwOnError $t');
            }
          }
        });
      }

      test('web gzip with verify checks zlib stream it falls back to', () {
        expect(const GZipDecoderWeb().decodeBytes(zlib, verify: true), data);
        expect(const GZipDecoder().decodeBytes(zlib, verify: true), data);
      });

      test('web decoders read input in big- and little-endian byte order', () {
        for (final order in ByteOrder.values) {
          for (final (decoder, bytes) in [
            (const GZipDecoderWeb(), gzip),
            (const ZLibDecoderWeb(), zlib),
          ]) {
            final input = InputMemoryStream(bytes, byteOrder: order);
            final output = OutputMemoryStream();
            expect(decoder.decodeStream(input, output, verify: true), isTrue,
                reason: '$decoder $order');
            expect(output.getBytes(), data);
            expect(input.byteOrder, order);
          }
        }
      });

      test('zlib verify accepts complete stream followed by extra bytes', () {
        final padded = Uint8List.fromList([...zlib, 0, 0, 0, 0]);
        expect(const ZLibDecoder().decodeBytes(padded, verify: true), data);
        expect(
            const ZLibDecoder().decodeStream(
                InputMemoryStream(padded), OutputMemoryStream(),
                verify: true),
            isTrue);
        expect(const GZipDecoder().decodeBytes(padded, verify: true), data);
        expect(
            const GZipDecoder().decodeStream(
                InputMemoryStream(padded), OutputMemoryStream(),
                verify: true),
            isTrue);
      });

      test('web zlib rejects invalid method and window fields', () {
        final valid = ZLibEncoder().encodeBytes([1, 2, 3, 4]);
        for (final (field, cmf) in [('method', 0x79), ('window', 0x88)]) {
          final bad = Uint8List.fromList(valid);
          bad[0] = cmf;
          bad[1] = (31 - ((cmf << 8) % 31)) % 31;
          expect(CodecsRecognizer.isZLib(bad), isFalse, reason: field);
          for (final (verify, throwOnError) in [(true, true), (false, true)]) {
            expect(
                () => const ZLibDecoderWeb().decodeBytes(bad,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: '$field, bytes, verify $verify');
            expect(
                () => const ZLibDecoderWeb().decodeStream(
                    InputMemoryStream(bad), OutputMemoryStream(),
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: '$field, stream, verify $verify');
          }
        }
      });

      test('web decoders with verify reject unfinished deflate blocks', () {
        for (final (name, decoder, bad) in [
          (
            'zlib',
            const ZLibDecoderWeb(),
            Uint8List.fromList([0x78, 0x9c, 0x03, 0xff, 0, 0, 0, 1])
          ),
          (
            'gzip',
            const GZipDecoderWeb(),
            Uint8List.fromList([
              0x1f,
              0x8b,
              8,
              0,
              0,
              0,
              0,
              0,
              0,
              0x13,
              0x03,
              0xff,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0
            ])
          ),
        ]) {
          for (final (verify, throwOnError) in [(true, true), (false, true)]) {
            expect(
                () => decoder.decodeBytes(bad,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: '$name bytes, verify $verify');
            expect(
                () => decoder.decodeStream(
                    InputMemoryStream(bad), OutputMemoryStream(),
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: '$name stream, verify $verify');
          }
        }
      });

      // Needs computed Adler-32 trailer, which made throwOnError 12-20% slower
      // on 100 and 500 MB, so test stays off
      // test('native zlib with verify rejects invalid deflate that has valid checksum',
      //     () {
      //   final bad = Uint8List.fromList([0x78, 0x9c, 0xfc, 0, 0, 0, 0, 1]);
      //   for (final (verify, throwOnError)
      //       in [(true, false), (false, true)]) {
      //     expect(
      //         () => const ZLibDecoder()
      //             .decodeBytes(bad,
      //                 verify: verify, throwOnError: throwOnError),
      //         throwsA(isA<ArchiveException>()),
      //         reason: 'bytes, verify $verify');
      //     expect(
      //         () => const ZLibDecoder().decodeStream(
      //             InputMemoryStream(bad), OutputMemoryStream(),
      //             verify: verify, throwOnError: throwOnError),
      //         throwsA(isA<ArchiveException>()),
      //         reason: 'stream, verify $verify');
      //   }
      // });

      // dart:io passes these streams without second inflate pass in Dart,
      // which made zlib verify 3.4x slower on enwik8, so tests stay off
      // test('native zlib with verify rejects stream without final deflate block', () {
      //   final bad = Uint8List.fromList([0x78, 0x9c, 0x9c, 0, 0, 0, 1, 0, 1]);
      //   expect(() => const ZLibDecoder().decodeBytes(bad, verify: true),
      //       throwsA(isA<ArchiveException>()));
      //   expect(
      //       () => const ZLibDecoder().decodeStream(
      //           InputMemoryStream(bad), OutputMemoryStream(),
      //           verify: true),
      //       throwsA(isA<ArchiveException>()));
      //   for (final size in [0, 1, 128, 4096, 65536]) {
      //     final source = List.generate(size, (i) => i & 255);
      //     final packed = ZLibEncoder().encodeBytes(source);
      //     expect(packed[2] & 1, 1);
      //     final unfinished = Uint8List.fromList(packed)..[2] ^= 1;
      //     expect(
      //         () => const ZLibDecoder()
      //             .decodeBytes(unfinished, verify: true),
      //         throwsA(isA<ArchiveException>()),
      //         reason: '$size bytes');
      //     expect(
      //         () => const ZLibDecoder().decodeStream(
      //             InputMemoryStream(unfinished), OutputMemoryStream(),
      //             verify: true),
      //         throwsA(isA<ArchiveException>()),
      //         reason: '$size bytes, stream');
      //   }
      // });
//
      // test('native zlib with verify rejects truncated final block followed by checksum',
      //     () {
      //   final bad = Uint8List.fromList([0x78, 0x9c, 0x03, 0, 0, 0, 1]);
      //   expect(() => const ZLibDecoder().decodeBytes(bad, verify: true),
      //       throwsA(isA<ArchiveException>()));
      //   expect(
      //       () => const ZLibDecoder().decodeStream(
      //           InputMemoryStream(bad), OutputMemoryStream(), verify: true),
      //       throwsA(isA<ArchiveException>()));
      // });
//
      // test('native zlib with verify rejects stream without final stored block', () {
      //   final valid = Uint8List.fromList([
      //     0x78, 0x01, 0, 1, 0, 0xfe, 0xff, 0x41,
      //     1, 1, 0, 0xfe, 0xff, 0x42, 0, 0xc6, 0, 0x84
      //   ]);
      //   expect(
      //       const ZLibDecoder().decodeBytes(valid, verify: true), [65, 66]);
      //   final bad = Uint8List.fromList(valid)..[8] = 0;
      //   expect(() => const ZLibDecoder().decodeBytes(bad, verify: true),
      //       throwsA(isA<ArchiveException>()));
      //   expect(
      //       () => const ZLibDecoder().decodeStream(
      //           InputMemoryStream(bad), OutputMemoryStream(), verify: true),
      //       throwsA(isA<ArchiveException>()));
      // });

      test('web zlib rejects oversubscribed Huffman table', () {
        final source = Uint8List.fromList(List.generate(16384, (i) => i & 255));
        final packed = ZLibEncoder().encodeBytes(source);
        final bad = Uint8List.fromList(packed)..[8] ^= 0xff;
        expect(
            const ZLibDecoderWeb().decodeBytes(packed, verify: true), source);
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => const ZLibDecoderWeb()
                  .decodeBytes(bad, verify: verify, throwOnError: throwOnError),
              throwsA(isA<ArchiveException>()),
              reason: 'bytes, verify $verify');
          expect(
              () => const ZLibDecoderWeb().decodeStream(
                  InputMemoryStream(bad), OutputMemoryStream(),
                  verify: verify, throwOnError: throwOnError),
              throwsA(isA<ArchiveException>()),
              reason: 'stream, verify $verify');
        }
      });

      // dart:io passes this input without second inflate pass in Dart,
      // too costly for verify as in zlib tests above, so test stays off
      // test('native gzip with verify rejects output larger than member ISIZE', () {
      //   final bad = Uint8List.fromList([
      //     0x1f,
      //     0x8b,
      //     8,
      //     0,
      //     0,
      //     0,
      //     0,
      //     0,
      //     0,
      //     0x13,
      //     0xf3,
      //     0xfe,
      //     0x7e,
      //     0x63,
      //     0x95,
      //     0xb3,
      //     0x53,
      //     0x64,
      //     6,
      //     0xff,
      //     0xfa,
      //     0xbd,
      //     0x59,
      //     0xa6,
      //     8,
      //     0,
      //     0,
      //     0
      //   ]);
      //   for (final (verify, throwOnError)
      //       in [(true, false), (false, true)]) {
      //     expect(
      //         () => const GZipDecoder()
      //             .decodeBytes(bad,
      //                 verify: verify, throwOnError: throwOnError),
      //         throwsA(isA<ArchiveException>()),
      //         reason: 'bytes, verify $verify');
      //     expect(
      //         () => const GZipDecoder().decodeStream(
      //             InputMemoryStream(bad), OutputMemoryStream(),
      //             verify: verify, throwOnError: throwOnError),
      //         throwsA(isA<ArchiveException>()),
      //         reason: 'stream, verify $verify');
      //   }
      // });

      test(
          'dart:io zlib verify with throwOnError throws on more than 4 KB '
          'after stream, web accepts',
          testOn: 'vm', () {
        final padded = Uint8List.fromList([...zlib, ...Uint8List(4097)]);
        expect(
            const ZLibDecoder().decodeBytes(padded, throwOnError: true), data);
        expect(
            () => const ZLibDecoder()
                .decodeBytes(padded, verify: true, throwOnError: true),
            throwsA(allOf(isA<ArchiveException>(),
                isNot(isA<ArchiveChecksumException>()))));
        expect(const ZLibDecoderWeb().decodeBytes(padded, verify: true), data);
      });

      test('decodeStream reads members whose trailer is split between 2 reads',
          () {
        final second = GZipEncoder().encodeBytes(List.filled(3000, 7));
        for (var k = 1; k <= 9; k++) {
          final data = Uint8List.fromList(
              List.generate(8192 + k - 23, (i) => i * 31 & 255));
          final crc = getCrc32(data);
          final first = OutputMemoryStream()
            ..writeBytes([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1])
            ..writeUint16(data.length)
            ..writeUint16(data.length ^ 0xffff)
            ..writeBytes(data)
            ..writeUint32(crc)
            ..writeUint32(data.length);
          expect(first.length, 8192 + k);
          final both = Uint8List.fromList([...first.getBytes(), ...second]);
          final want = [...data, ...List.filled(3000, 7)];
          for (final (verify, throwOnError) in [
            (false, false),
            (true, false),
            (false, true)
          ]) {
            final out = OutputMemoryStream();
            const GZipDecoder().decodeStream(InputMemoryStream(both), out,
                verify: verify, throwOnError: throwOnError);
            expect(out.getBytes(), want, reason: 'k $k, verify $verify');
          }
        }
      });

      test('members after empty member are decoded', () {
        final first = GZipEncoder().encodeBytes(List.filled(5000, 65));
        final empty = GZipEncoder().encodeBytes(const <int>[]);
        final last = GZipEncoder().encodeBytes(List.filled(3000, 66));
        final random = Random(2);
        final large = List.generate(20000, (_) => random.nextInt(256));
        for (final (joined, expected) in [
          (
            [...first, ...empty, ...last],
            [...List.filled(5000, 65), ...List.filled(3000, 66)]
          ),
          ([...empty, ...last], List.filled(3000, 66)),
          (
            [...first, ...empty, ...GZipEncoder().encodeBytes(large)],
            [...List.filled(5000, 65), ...large]
          ),
        ]) {
          final bytes = Uint8List.fromList(joined);
          for (final (verify, throwOnError) in [
            (false, false),
            (true, false),
            (false, true)
          ]) {
            final reason = 'length ${bytes.length}, verify $verify, '
                'throwOnError $throwOnError';
            expect(
                const GZipDecoder().decodeBytes(bytes,
                    verify: verify, throwOnError: throwOnError),
                expected,
                reason: reason);
            final out = OutputMemoryStream();
            expect(
                const GZipDecoder().decodeStream(InputMemoryStream(bytes), out,
                    verify: verify, throwOnError: throwOnError),
                isTrue,
                reason: reason);
            expect(out.getBytes(), expected, reason: reason);
          }
        }
      });

      test(
          'member after empty member is kept when read ends on member boundary',
          () {
        final random = Random(1);
        final empty = GZipEncoder().encodeBytes(const <int>[]);
        final middle = GZipEncoder().encodeBytes(List.filled(300, 67));
        final last = GZipEncoder().encodeBytes(List.filled(3000, 68));
        var size = 8192;
        late List<int> data;
        late List<int> first;
        do {
          size--;
          data = List.generate(size, (_) => random.nextInt(256));
          first = GZipEncoder().encodeBytes(data);
        } while (first.length + empty.length + middle.length > 8192);
        expect(first.length + empty.length + middle.length, 8192);
        final bytes =
            Uint8List.fromList([...first, ...empty, ...middle, ...last]);
        final out = OutputMemoryStream();
        expect(
            const GZipDecoder().decodeStream(InputMemoryStream(bytes), out,
                throwOnError: true),
            isTrue);
        expect(out.getBytes(),
            [...data, ...List.filled(300, 67), ...List.filled(3000, 68)]);
      });

      test(
          'stored bytes that look like empty gzip member are not member boundary',
          () {
        final random = Random(4);
        final nested = GZipEncoder()
            .encodeBytes(List.generate(1000, (_) => random.nextInt(256)));
        final tar = TarEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('a.txt', 'hello'.codeUnits))
          ..add(ArchiveFile.bytes('b.gz', nested)));
        final stored = GZipEncoder().encodeBytes(tar, level: 0);
        final empty = GZipEncoder().encodeBytes(const <int>[]);
        final last = GZipEncoder().encodeBytes(List.filled(3000, 69));
        final long = List.generate(20000, (_) => random.nextInt(256));
        final tarOfMembers = TarEncoder().encodeBytes(
            Archive()..add(ArchiveFile.bytes('c.gz', [...empty, ...nested])));
        for (final (joined, expected) in [
          (stored, tar),
          ([...stored, ...empty, ...last], [...tar, ...List.filled(3000, 69)]),
          (
            [...stored, ...empty, ...GZipEncoder().encodeBytes(long)],
            [...tar, ...long]
          ),
          (GZipEncoder().encodeBytes(tarOfMembers, level: 0), tarOfMembers),
        ]) {
          final bytes = Uint8List.fromList(joined);
          for (final (verify, throwOnError) in [
            (false, false),
            (true, false),
            (false, true)
          ]) {
            final reason = 'length ${bytes.length}, verify $verify, '
                'throwOnError $throwOnError';
            expect(
                const GZipDecoder().decodeBytes(bytes,
                    verify: verify, throwOnError: throwOnError),
                expected,
                reason: reason);
            final out = OutputMemoryStream();
            expect(
                const GZipDecoder().decodeStream(InputMemoryStream(bytes), out,
                    verify: verify, throwOnError: throwOnError),
                isTrue,
                reason: reason);
            expect(out.getBytes(), expected, reason: reason);
          }
        }
      });

      test('web raw inflate decodes last code that ends exactly at end of data',
          () {
        final raw = Uint8List.fromList([155, 48, 113, 210, 228, 41, 0]);
        for (final throwOnError in [false, true]) {
          expect(
              const ZLibDecoderWeb()
                  .decodeBytes(raw, raw: true, throwOnError: throwOnError),
              [0x90, 0x91, 0x92, 0x93, 0x94]);
        }
      });

      test('web zlib decodes complete stream followed by extra bytes', () {
        final padded = Uint8List.fromList([...zlib, 0, 0, 0, 0]);
        expect(const ZLibDecoderWeb().decodeBytes(padded), data);
        expect(const ZLibDecoder().decodeBytes(padded), data);
      });

      test('web decoders reject truncated stream read from file', testOn: 'vm',
          () {
        for (final (decoder, whole) in [
          (const GZipDecoderWeb(), gzip),
          (const ZLibDecoderWeb(), zlib),
        ]) {
          for (final cut in [whole.length ~/ 2, whole.length - 1]) {
            final path = '$testOutputPath/cut_${decoder.runtimeType}_$cut.bin';
            File(path).writeAsBytesSync(Uint8List.sublistView(whole, 0, cut));
            final input = InputFileStream(path);
            try {
              expect(
                  () => decoder.decodeStream(input, OutputMemoryStream(),
                      throwOnError: true),
                  throwsA(allOf(isA<ArchiveException>(),
                      isNot(isA<ArchiveChecksumException>()))),
                  reason: '$decoder cut at $cut');
            } finally {
              input.closeSync();
            }
          }
        }
      });

      test('web zlib rejects truncated raw stream with throwOnError', () {
        final raw = Deflate(data).getBytes();
        expect(const ZLibDecoderWeb().decodeBytes(raw, raw: true, verify: true),
            data);
        for (final cut in [0, raw.length ~/ 2]) {
          final bad = Uint8List.sublistView(raw, 0, cut);
          for (final (v, t) in [(true, true), (false, true)]) {
            expect(
                () => const ZLibDecoderWeb()
                    .decodeBytes(bad, raw: true, verify: v, throwOnError: t),
                throwsA(isA<ArchiveException>()),
                reason: 'cut at $cut, verify $v, throwOnError $t');
          }
        }
      });

      test(
          'without flags decodeBytes returns same bytes as decodeStream writes',
          () {
        final padded = Uint8List.fromList([...gzip, ...Uint8List(600)]);
        final output = OutputMemoryStream();
        expect(
            const GZipDecoder().decodeStream(InputMemoryStream(padded), output),
            isFalse);
        expect(output.getBytes(), data);
        expect(const GZipDecoder().decodeBytes(padded), output.getBytes());
      });

      test('web decoders with verify check NLEN of empty stored block', () {
        for (final complement in [0, 1, 0x7fff, 0xfffe, 0xffff]) {
          final raw = [1, 0, 0, complement & 0xff, complement >> 8];
          final zlib = [0x78, 0x9c, ...raw, 0, 0, 0, 1];
          final gzip = [
            0x1f,
            0x8b,
            8,
            0,
            0,
            0,
            0,
            0,
            0,
            3,
            ...raw,
            ...List<int>.filled(8, 0)
          ];
          for (final (verify, throwOnError) in [(true, true), (false, true)]) {
            final decodes = [
              () => const ZLibDecoderWeb().decodeBytes(raw,
                  raw: true, verify: verify, throwOnError: throwOnError),
              () => const ZLibDecoderWeb().decodeBytes(zlib,
                  verify: verify, throwOnError: throwOnError),
              () => const GZipDecoderWeb()
                  .decodeBytes(gzip, verify: verify, throwOnError: throwOnError)
            ];
            for (final decode in decodes) {
              if (complement == 0xffff) {
                expect(decode(), isEmpty);
              } else {
                expect(decode, throwsA(isA<ArchiveException>()),
                    reason: 'complement $complement');
              }
            }
          }
        }
      });

      test('web zlib with verify rejects literal alphabet above 286 symbols',
          () {
        for (final encoded in [
          'eJz1wAUEAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAIAAAAAAAQ==',
          'eJz9wAUEAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAABAAAAAQ=='
        ]) {
          final packed = base64Decode(encoded);
          for (final (verify, throwOnError) in [(true, true), (false, true)]) {
            expect(
                () => const ZLibDecoderWeb().decodeBytes(packed,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()));
          }
        }
        final valid = base64Decode(
            'eJztwAUEAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAEAAAAAAAQ==');
        expect(
            const ZLibDecoderWeb().decodeBytes(valid, verify: true), isEmpty);
      });

      test(
          'web zlib with verify rejects repeat code without previous code length',
          () {
        final packed = base64Decode(
            'eJwFwAUEAAAAAKABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAAAB');
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => const ZLibDecoderWeb().decodeBytes(packed,
                  verify: verify, throwOnError: throwOnError),
              throwsA(isA<ArchiveException>()));
        }
        final valid = base64Decode(
            'eJwFwAUEAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAIAAAAB');
        expect(
            const ZLibDecoderWeb().decodeBytes(valid, verify: true), isEmpty);
      });

      test('web decoders keep output when zlib checksum is truncated', () {
        for (final decoder in [
          const ZLibDecoderWeb(),
          const GZipDecoderWeb()
        ]) {
          for (var cut = 1; cut <= 4; cut++) {
            final damaged = Uint8List.sublistView(zlib, 0, zlib.length - cut);
            final output = OutputMemoryStream();
            expect(decoder.decodeStream(InputMemoryStream(damaged), output),
                isFalse);
            expect(output.getBytes(), data, reason: 'cut $cut');
            expect(decoder.decodeBytes(damaged), data, reason: 'cut $cut');
            for (final (verify, throwOnError) in [
              (true, true),
              (false, true)
            ]) {
              expect(
                  () => decoder.decodeBytes(damaged,
                      verify: verify, throwOnError: throwOnError),
                  throwsA(isA<ArchiveException>()));
            }
          }
        }
      });

      test('web decoders keep output on checksum mismatch with verify', () {
        final badGzip = Uint8List.fromList(gzip)..[gzip.length - 8] ^= 1;
        final gzipOut = OutputMemoryStream();
        expect(
            const GZipDecoderWeb().decodeStream(
                InputMemoryStream(badGzip), gzipOut,
                verify: true, throwOnError: false),
            isFalse);
        expect(gzipOut.getBytes(), data);
        final badZlib = Uint8List.fromList(zlib)..[zlib.length - 1] ^= 1;
        final zlibOut = OutputMemoryStream();
        expect(
            const ZLibDecoderWeb().decodeStream(
                InputMemoryStream(badZlib), zlibOut,
                verify: true, throwOnError: false),
            isFalse);
        expect(zlibOut.getBytes(), data);
        expect(
            const ZLibDecoderWeb()
                .decodeBytes(badZlib, verify: true, throwOnError: false),
            data);
      });

      test('verify alone throws on checksum mismatch', () {
        final badGzip = Uint8List.fromList(gzip)..[gzip.length - 8] ^= 1;
        final badZlib = Uint8List.fromList(zlib)..[zlib.length - 1] ^= 1;
        for (final decode in [
          () => const GZipDecoderWeb().decodeBytes(badGzip, verify: true),
          () => const ZLibDecoderWeb().decodeBytes(badZlib, verify: true),
          () => GZipDecoder().decodeBytes(badGzip, verify: true),
          () => ZLibDecoder().decodeBytes(badZlib, verify: true),
        ]) {
          expect(decode, throwsA(isA<ArchiveException>()));
        }
      });

      test('dart:io decoders keep output when trailer is truncated', () {
        for (final (packed, trailer, decodeBytes, decodeStream) in [
          (
            gzip,
            8,
            const GZipDecoder().decodeBytes,
            const GZipDecoder().decodeStream
          ),
          (
            zlib,
            4,
            const ZLibDecoder().decodeBytes,
            const ZLibDecoder().decodeStream
          ),
        ]) {
          for (var cut = 1; cut <= trailer; cut++) {
            final damaged =
                Uint8List.sublistView(packed, 0, packed.length - cut);
            expect(decodeBytes(damaged), data, reason: 'cut $cut');
            final output = OutputMemoryStream();
            decodeStream(InputMemoryStream(damaged), output);
            expect(output.getBytes(), data, reason: 'cut $cut');
          }
        }
      });

      test(
          'decodeBytes of truncated gzip does not size output from bytes at cut',
          () {
        final random = Random(3);
        final text = Uint8List.fromList(
            List.generate(1 << 20, (_) => random.nextInt(16) + 97));
        final packed = Uint8List.fromList(GZipEncoder().encodeBytes(text));
        for (var cut = packed.length ~/ 4;
            cut < packed.length - 8;
            cut += packed.length ~/ 4) {
          final out = const GZipDecoder()
              .decodeBytes(Uint8List.sublistView(packed, 0, cut));
          expect(out.buffer.lengthInBytes, lessThan(32 << 20),
              reason: 'cut $cut of ${packed.length}');
        }
      });

      test('decodeBytes with verify and throwOnError throws on wrong gzip CRC',
          () {
        final damaged = Uint8List.fromList(gzip)..[gzip.length - 8] ^= 0xff;
        expect(
            () => const GZipDecoder()
                .decodeBytes(damaged, verify: true, throwOnError: true),
            throwsA(isA<ArchiveChecksumException>()));
      });

      test('without flags zlib decodeBytes returns bytes decoded before damage',
          () {
        final random = Random(3);
        final text = Uint8List.fromList(
            List.generate(300000, (_) => random.nextInt(16) + 97));
        final packed = Uint8List.fromList(ZLibEncoder().encodeBytes(text));
        for (var at = packed.length ~/ 2; at < packed.length - 4; at += 997) {
          final damaged = Uint8List.fromList(packed)..[at] ^= 0xff;
          final output = OutputMemoryStream();
          if (const ZLibDecoder()
                  .decodeStream(InputMemoryStream(damaged), output) ||
              output.length == 0) {
            continue;
          }
          final bytes = const ZLibDecoder().decodeBytes(damaged);
          final streamed = output.getBytes();
          final common = min(bytes.length, streamed.length);
          expect(bytes, isNotEmpty, reason: 'damage at $at');
          expect(Uint8List.sublistView(bytes, 0, common),
              Uint8List.sublistView(streamed, 0, common),
              reason: 'damage at $at');
          return;
        }
        fail('no damage made the stream fail after some output');
      });

      test(
          'gzip verify with throwOnError throws on 1 zero byte after last member',
          () {
        final padded = Uint8List.fromList([...gzip, 0]);
        for (final (name, decode) in [
          (
            'gzip',
            (Uint8List bytes) => const GZipDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true)
          ),
          (
            'gzip web',
            (Uint8List bytes) => const GZipDecoderWeb()
                .decodeBytes(bytes, verify: true, throwOnError: true)
          ),
        ]) {
          expect(() => decode(padded), throwsA(isA<ArchiveException>()),
              reason: name);
        }
      });

      test(
          'gzip verify with throwOnError throws on truncated header after '
          'empty last member', () {
        final whole = Uint8List.fromList(
            [...gzip, ...GZipEncoder().encodeBytes(Uint8List(0))]);
        expect(const GZipDecoder().decodeBytes(whole, verify: true), data);
        const header = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3];
        for (var cut = 3; cut <= 9; cut++) {
          final padded =
              Uint8List.fromList([...whole, ...header.sublist(0, cut)]);
          expect(
              () => const GZipDecoder()
                  .decodeBytes(padded, verify: true, throwOnError: true),
              throwsA(isA<ArchiveException>()),
              reason: 'bytes, cut $cut');
          expect(
              () => const GZipDecoder().decodeStream(
                  InputMemoryStream(padded), OutputMemoryStream(),
                  verify: true, throwOnError: true),
              throwsA(isA<ArchiveException>()),
              reason: 'stream, cut $cut');
        }
      });

      test('gzip verify and throwOnError throw on input cut inside member', () {
        final zeros = Uint8List(300000);
        final text = Uint8List.fromList(
            List.generate(50000, (i) => 97 + (i * 7 + i ~/ 13) % 26));
        final none = Uint8List(0);
        final inputs = [
          [zeros],
          [zeros, text],
          [zeros, none],
          [none, text],
          [none, text, none, none],
        ];
        for (final members in inputs) {
          final bytes = <int>[];
          final ends = <int>[];
          for (final member in members) {
            bytes.addAll(GZipEncoder().encodeBytes(member));
            ends.add(bytes.length);
          }
          final whole = Uint8List.fromList(bytes);
          final expected = [for (final member in members) ...member];
          final sizes = [for (final member in members) member.length];
          for (final (v, t) in [(true, false), (false, true)]) {
            expect(
                const GZipDecoder()
                    .decodeBytes(whole, verify: v, throwOnError: t),
                expected,
                reason: 'members $sizes, verify $v');
            final output = OutputMemoryStream();
            expect(
                const GZipDecoder().decodeStream(
                    InputMemoryStream(whole), output,
                    verify: v, throwOnError: t),
                isTrue,
                reason: 'members $sizes, verify $v');
            expect(output.getBytes(), expected);
          }
          for (var cut = 1; cut < whole.length; cut++) {
            if (ends.contains(cut)) {
              continue;
            }
            final part = Uint8List.sublistView(whole, 0, cut);
            for (final (v, t) in [
              (true, true),
              if (members.first.isNotEmpty) (false, true)
            ]) {
              final reason = 'members $sizes, cut $cut, verify $v';
              expect(
                  () => const GZipDecoder()
                      .decodeBytes(part, verify: v, throwOnError: t),
                  throwsA(isA<ArchiveException>()),
                  reason: 'bytes, $reason');
              expect(
                  () => const GZipDecoder().decodeStream(
                      InputMemoryStream(part), OutputMemoryStream(),
                      verify: v, throwOnError: t),
                  throwsA(isA<ArchiveException>()),
                  reason: 'stream, $reason');
            }
          }
        }
      });

      test('gzip verify and throwOnError throw on member cut in extra field',
          () {
        const header = [0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 3, 0, 1, 0, 0, 0, 0];
        final cut = Uint8List.fromList(
            [...GZipEncoder().encodeBytes(Uint8List(300000)), ...header]);
        for (final (v, t) in [(true, true), (false, true)]) {
          expect(
              () => const GZipDecoder()
                  .decodeBytes(cut, verify: v, throwOnError: t),
              throwsA(isA<ArchiveException>()),
              reason: 'bytes, verify $v');
          expect(
              () => const GZipDecoder().decodeStream(
                  InputMemoryStream(cut), OutputMemoryStream(),
                  verify: v, throwOnError: t),
              throwsA(isA<ArchiveException>()),
              reason: 'stream, verify $v');
        }
      });

      test('gzip verify and throwOnError throw on junk after empty member', () {
        final first = GZipEncoder().encodeBytes(List.filled(300, 65));
        final empty = GZipEncoder().encodeBytes(const <int>[]);
        final last = GZipEncoder().encodeBytes(List.filled(500, 66));
        for (final junk in [
          [0],
          [...'junk'.codeUnits, ...Uint8List(8)]
        ]) {
          final bytes =
              Uint8List.fromList([...first, ...empty, ...junk, ...last]);
          for (final (v, t) in [(true, true), (false, true)]) {
            final reason = 'junk ${junk.length} bytes, verify $v';
            expect(
                () => const GZipDecoder()
                    .decodeBytes(bytes, verify: v, throwOnError: t),
                throwsA(isA<ArchiveException>()),
                reason: 'bytes, $reason');
            expect(
                () => const GZipDecoder().decodeStream(
                    InputMemoryStream(bytes), OutputMemoryStream(),
                    verify: v, throwOnError: t),
                throwsA(isA<ArchiveException>()),
                reason: 'stream, $reason');
          }
        }
      });

      test('gzip throws on junk after second empty member', () {
        final first = GZipEncoder().encodeBytes(List.filled(300, 65));
        final empty = GZipEncoder().encodeBytes(const <int>[]);
        final middle = GZipEncoder().encodeBytes(List.filled(200, 67));
        final last = GZipEncoder().encodeBytes(List.filled(500, 66));
        final bytes = Uint8List.fromList(
            [...first, ...empty, ...middle, ...empty, 0, ...last]);
        for (final (v, t) in [(true, true), (false, true)]) {
          expect(
              () => const GZipDecoder()
                  .decodeBytes(bytes, verify: v, throwOnError: t),
              throwsA(isA<ArchiveException>()),
              reason: 'bytes, verify $v');
          expect(
              () => const GZipDecoder().decodeStream(
                  InputMemoryStream(bytes), OutputMemoryStream(),
                  verify: v, throwOnError: t),
              throwsA(isA<ArchiveException>()),
              reason: 'stream, verify $v');
        }
        expect(const GZipDecoder().decodeBytes(bytes).length, 500);
        expect(
            const GZipDecoder()
                .decodeStream(InputMemoryStream(bytes), OutputMemoryStream()),
            isFalse);
      });

      test('gzip reads member after empty member with long header', () {
        var state = 3;
        final data = Uint8List.fromList(List.generate(200000, (_) {
          state = (state * 75 + 74) % 65537;
          return state & 0xff;
        }));
        final member = GZipEncoder().encodeBytes(data);
        for (final (flag, length) in [(4, 60000), (8, 100000), (16, 2000)]) {
          final header = [0x1f, 0x8b, 8, flag, 0, 0, 0, 0, 0, 3];
          final fields = flag == 4
              ? [length & 0xff, length >> 8, ...List.filled(length, 65)]
              : [...List.filled(length, 65), 0];
          final bytes = Uint8List.fromList([
            ...member,
            ...header,
            ...fields,
            ...[3, 0],
            ...Uint8List(8),
            ...member
          ]);
          for (final (v, t) in [(false, false), (true, false), (false, true)]) {
            final reason = 'flag $flag, verify $v, throwOnError $t';
            expect(
                const GZipDecoder()
                    .decodeBytes(bytes, verify: v, throwOnError: t)
                    .length,
                400000,
                reason: 'bytes, $reason');
            final out = OutputMemoryStream();
            expect(
                const GZipDecoder().decodeStream(InputMemoryStream(bytes), out,
                    verify: v, throwOnError: t),
                isTrue,
                reason: 'stream, $reason');
            expect(out.length, 400000, reason: 'stream, $reason');
          }
        }
      });

      test('gzip stream reads member after empty member with long comment', () {
        final first = GZipEncoder().encodeBytes(List.filled(300, 65));
        final empty = [
          ...[0x1f, 0x8b, 8, 16, 0, 0, 0, 0, 0, 3],
          ...List.filled(2000, 65),
          ...[0, 3, 0],
          ...Uint8List(8)
        ];
        final last = GZipEncoder().encodeBytes(List.filled(500, 66));
        final bytes = Uint8List.fromList([...first, ...empty, ...last]);
        for (final (v, t) in [(false, false), (true, false), (false, true)]) {
          final out = OutputMemoryStream();
          expect(
              const GZipDecoder().decodeStream(InputMemoryStream(bytes), out,
                  verify: v, throwOnError: t),
              isTrue,
              reason: 'verify $v, throwOnError $t');
          expect(out.getBytes(),
              [...List.filled(300, 65), ...List.filled(500, 66)]);
        }
      });

      test(
          'web zlib ignores bytes after complete stream with verify or throwOnError',
          () {
        for (final tail in [
          [0],
          [0, 0, 0, 0],
          [1, 2, 3, 4, 5, 6, 7, 8, 9]
        ]) {
          final padded = Uint8List.fromList([...zlib, ...tail]);
          for (final (v, t) in [(true, false), (false, true)]) {
            expect(
                const ZLibDecoderWeb()
                    .decodeBytes(padded, verify: v, throwOnError: t),
                data,
                reason: 'tail $tail, verify $v, throwOnError $t');
          }
        }
      });

      test('web zlib decodes only first of concatenated streams', () {
        final joined = Uint8List.fromList([...zlib, ...zlib]);
        expect(const ZLibDecoderWeb().decodeBytes(joined), data);
        final out = OutputMemoryStream();
        expect(
            const ZLibDecoderWeb().decodeStream(InputMemoryStream(joined), out),
            isTrue);
        expect(out.getBytes(), data);
      });
    });

    test('web decoder writes 2 members to file and to write-only sink',
        testOn: 'vm', () {
      final data = Uint8List(3 * 1024 * 1024 + 12345);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 31 + (i >> 11)) & 0xff;
      }
      final one = Uint8List.fromList(GZipEncoder().encodeBytes(data));
      final gz = Uint8List.fromList([...one, ...one]);
      final want = [...data, ...data];

      final path = '$testOutputPath/web_decode.bin';
      final file = OutputFileStream(path);
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(gz), file, verify: true),
          isTrue);
      file.closeSync();
      expect(File(path).readAsBytesSync(), want);

      List<List<int>>? chunks;
      final sink = SinkOutputStream(
          ChunkedConversionSink<List<int>>.withCallback((all) => chunks = all));
      expect(
          GZipDecoderWeb().decodeStream(InputMemoryStream(gz), sink), isTrue);
      sink.sink.close();
      expect(chunks!.expand((c) => c).toList(), want);
    });

    test('small decodeBytes result is not view of larger output buffer',
        testOn: 'vm', () {
      final data = [1, 2, 3, 4, 5];
      final packed = const GZipEncoder().encodeBytes(data);
      for (final (verify, throwOnError) in [
        (false, false),
        (false, true),
        (true, false)
      ]) {
        final out = GZipDecoder()
            .decodeBytes(packed, verify: verify, throwOnError: throwOnError);
        expect(out, data);
        expect(out.buffer.lengthInBytes, data.length,
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });
  });
}

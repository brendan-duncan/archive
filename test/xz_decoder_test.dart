import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/xz/xz_stream_decoder.dart'
    show XZStreamDecoder;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Decoder behaviours that the archives in xz_test.dart do not reach. Each one
// here is either a format feature the upstream decoder rejected or got wrong,
// or an API this package added, and every archive was produced by xz itself
// and checked with `xz -t`.

Uint8List archiveBytes(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

/// The content of `pb4.xz`, rebuilt rather than committed beside it.
Uint8List pb4Sample() {
  const pattern = 'the quick brown fox jumps over the lazy dog 0123456789\n';
  final bytes = <int>[];
  while (bytes.length < 500) {
    bytes.addAll(pattern.codeUnits);
  }
  return Uint8List.fromList(bytes.sublist(0, 500));
}

/// The content of `x86.xz`. The e8 call operands are what the BCJ x86 filter
/// rewrites, so decoding without the filter gives visibly different bytes.
Uint8List x86Sample() {
  final data = <int>[];
  var i = 0;
  while (data.length < 4000) {
    if (i % 17 == 0) {
      final target = (i * 7919) & 0xffffffff;
      data.addAll([
        0xe8,
        target & 0xff,
        (target >> 8) & 0xff,
        (target >> 16) & 0xff,
        (target >> 24) & 0xff,
      ]);
    } else {
      data.add((i * 31) & 0xff);
    }
    i++;
  }
  return Uint8List.fromList(data.sublist(0, 4000));
}

void main() {
  test('stops on a file cut off at any point', testOn: 'vm', () {
    final compressed =
        XZEncoder().encodeBytes(List<int>.generate(1000, (i) => i * 7 & 0xff));
    final dir = Directory.systemTemp.createTempSync('xz_truncated');
    try {
      final path = p.join(dir.path, 'truncated.xz');
      for (var n = 1; n < compressed.length; n++) {
        // Truncated inside a header or before the padding after a block,
        // reading padding up to a four byte boundary never ended.
        File(path).writeAsBytesSync(compressed.sublist(0, n));
        final input = InputFileStream(path);
        try {
          expect(XZDecoder().decodeStream(input, OutputMemoryStream()), isFalse,
              reason: 'cut at $n');
        } catch (e) {
          expect(e, isA<ArchiveException>(), reason: 'cut at $n');
        } finally {
          input.closeSync();
        }
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  group('xz block headers', () {
    // Builds a stream whose single block header carries [filters] and, when
    // given, a declared uncompressed length. There is no compressed data
    // behind it: every test here is about what the header alone can make the
    // decoder do.
    Uint8List streamWith({List<int>? rawLength, List<int>? filters}) {
      final body = <int>[
        (filters == null ? 0 : (filters[0] - 1)) |
            (rawLength != null ? 0x80 : 0),
        if (rawLength != null) ...rawLength,
        if (filters != null) ...filters.skip(1),
      ];
      var headerLength = 1 + body.length + 4;
      headerLength = (headerLength + 3) & ~3;
      final header = <int>[headerLength ~/ 4 - 1, ...body];
      while (header.length < headerLength - 4) {
        header.add(0);
      }
      Uint8List u32(int v) =>
          (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
      const streamFlags = [0x00, 0x01];
      return Uint8List.fromList([
        0xfd,
        0x37,
        0x7a,
        0x58,
        0x5a,
        0x00,
        ...streamFlags,
        ...u32(getCrc32(streamFlags)),
        ...header,
        ...u32(getCrc32(header)),
      ]);
    }

    // The x86 BCJ filter in front of LZMA2, which is what makes the decoder
    // buffer the block instead of writing it straight through.
    const bcjThenLzma2 = [2, 0x04, 0x00, 0x21, 0x01, 0x00];

    // A sink that is not an OutputMemoryStream, so the buffered path is taken.
    OutputStream sink() =>
        OutputFileStream(p.join(Directory.systemTemp.path, 'xz_header.out'));

    String reasonFor(Uint8List archive) {
      try {
        XZDecoder().decodeStream(InputMemoryStream(archive), sink(),
            verify: true, throwOnError: true);
      } on ArchiveException catch (e) {
        // The decoder prefixes the reason it recorded; the tests are about
        // which reason came back, not about that wrapper.
        return e.message.replaceFirst('Invalid XZ archive: ', '');
      }
      return '';
    }

    test('does not size a buffer from the length the header declares',
        testOn: 'vm', () {
      // 16 TB, declared by 32 bytes of header. Allocating that up front is an
      // OutOfMemoryError on the VM and a dead page on the web, so the decoder
      // has to reach the missing compressed data instead of the allocator.
      final archive = streamWith(
          rawLength: [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x04],
          filters: bcjThenLzma2);
      expect(archive.length, lessThan(64));
      expect(reasonFor(archive), isNot(contains('Out of Memory')));
    });

    test('rejects a multibyte integer longer than nine bytes', testOn: 'vm',
        () {
      // Nine is the cap in the format. Past it the multiplier overflows and
      // the value stops meaning anything, negative values included.
      for (final count in [9, 10, 11]) {
        final archive = streamWith(
            rawLength: [...List.filled(count, 0xff), 0x00],
            filters: bcjThenLzma2);
        expect(
            reasonFor(archive), 'Invalid uncompressed length in block header',
            reason: '$count continuation bytes');
      }
    });

    test('rejects a multibyte integer that runs to the end of the header',
        testOn: 'vm', () {
      final header = <int>[15, 0x81, ...List.filled(58, 0xff)];
      Uint8List u32(int v) =>
          (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
      const streamFlags = [0x00, 0x01];
      final archive = Uint8List.fromList([
        0xfd,
        0x37,
        0x7a,
        0x58,
        0x5a,
        0x00,
        ...streamFlags,
        ...u32(getCrc32(streamFlags)),
        ...header,
        ...u32(getCrc32(header)),
      ]);
      expect(reasonFor(archive), 'Invalid uncompressed length in block header');
    });

    test('rejects a filter whose properties field is empty', testOn: 'vm', () {
      expect(reasonFor(streamWith(filters: [1, 0x21, 0x00])),
          'Invalid LZMA dictionary size');
      expect(reasonFor(streamWith(filters: [2, 0x03, 0x00, 0x21, 0x01, 0x00])),
          'Invalid delta filter distance');
    });

    test('rejects a filter whose properties run past the header', testOn: 'vm',
        () {
      for (final id in [0x03, 0x04, 0x21]) {
        expect(reasonFor(streamWith(filters: [1, id, 0x04])),
            'Invalid filter in block header',
            reason: 'filter 0x${id.toRadixString(16)}');
      }
    });

    test('still reaches the data when the header is well formed', testOn: 'vm',
        () {
      // The same shape with a valid properties byte gets past every check
      // above, so the rejections are about the headers and not the archive
      // being a stub.
      expect(reasonFor(streamWith(filters: [1, 0x21, 0x01, 0x00])),
          'LZMA2 data ended without an end marker');
    });
  });

  test('stream decoder reports a cut archive without RangeError', testOn: 'vm',
      () {
    for (final name in ['hello-hello-hello.xz', 'cat.jpg.xz']) {
      final bytes = File('test/_data/xz/$name').readAsBytesSync();
      for (var n = 1; n < bytes.length; n++) {
        if (n > 200 && n < bytes.length - 200 && n % 97 != 0) {
          continue;
        }
        final decoder = XZStreamDecoder(maxPreallocateSize: 1 << 20);
        try {
          expect(
              decoder.decode(
                  InputMemoryStream(bytes.sublist(0, n)), OutputMemoryStream()),
              isFalse,
              reason: '$name cut at $n');
        } on ArchiveException {
          // LZMA decoder throws ArchiveException for chunk cut inside its data
        }
      }
    }
  });

  test('LZMA decoder reports damaged data as ArchiveException', () {
    final random = Random(1);
    var thrown = 0;
    for (var i = 0; i < 300; i++) {
      final bytes = Uint8List.fromList(
          [0, for (var j = 0; j < 63; j++) random.nextInt(256)]);
      final decoder = LzmaDecoder()
        ..reset(
            positionBits: 2,
            literalPositionBits: 0,
            literalContextBits: 3,
            resetDictionary: true);
      try {
        decoder.decode(InputMemoryStream(bytes), 4096);
      } catch (error) {
        thrown++;
        expect(error, isA<ArchiveException>(), reason: 'seed $i');
      }
    }
    expect(thrown, greaterThan(0));
  });

  group('xz verify and throwOnError', () {
    bool decode(Uint8List bytes, bool verify, bool throwOnError) =>
        XZDecoder().decodeStream(InputMemoryStream(bytes), OutputMemoryStream(),
            verify: verify, throwOnError: throwOnError);

    test('wrong check throws only with verify and throwOnError', testOn: 'vm',
        () async {
      final bad = Uint8List.fromList(archiveBytes('crc64.xz'));
      bad[bad.length - 21] ^= 0xff;
      expect(decode(bad, false, false), isTrue);
      expect(decode(bad, false, true), isTrue);
      expect(decode(bad, true, false), isFalse);
      expect(() => decode(bad, true, true),
          throwsA(isA<ArchiveChecksumException>()));
      await expectLater(Stream<List<int>>.value(bad).transform(xzCodec.decoder),
          emitsThrough(emitsError(isA<ArchiveChecksumException>())));
    });

    test('truncated or foreign data throws with throwOnError', testOn: 'vm',
        () {
      final whole = archiveBytes('crc64.xz');
      for (final bad in [
        Uint8List.sublistView(whole, 0, whole.length ~/ 2),
        Uint8List.fromList(List.filled(40, 7)),
      ]) {
        expect(decode(bad, false, false), isFalse);
        expect(decode(bad, true, false), isFalse);
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => decode(bad, verify, throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))),
              reason: 'verify $verify, throwOnError $throwOnError');
        }
      }
    });

    test('truncated archive returns start of data and nothing else',
        testOn: 'vm', () {
      final path = p.join(Directory.systemTemp.path, 'xz_cut_$pid.bin');
      for (final name in [
        'hello-hello-hello.xz',
        'good-1-lzma2-1.xz',
        'x86.xz'
      ]) {
        final whole = archiveBytes(name);
        final data = XZDecoder().decodeBytes(whole, verify: true);
        for (var cut = 0; cut < whole.length; cut++) {
          final bad = Uint8List.sublistView(whole, 0, cut);
          final output = OutputMemoryStream();
          XZDecoder().decodeStream(InputMemoryStream(bad), output);
          final file = OutputFileStream(path);
          XZDecoder().decodeStream(InputMemoryStream(bad), file);
          file.closeSync();
          for (final decoded in [
            XZDecoder().decodeBytes(bad),
            output.getBytes(),
            File(path).readAsBytesSync()
          ]) {
            expect(decoded.length, lessThanOrEqualTo(data.length),
                reason: '$name cut at $cut');
            expect(decoded, Uint8List.sublistView(data, 0, decoded.length),
                reason: '$name cut at $cut');
          }
        }
      }
      File(path).deleteSync();
    });
  });

  group('xz decoder', () {
    test('decodes an archive written with pb=4', testOn: 'vm', () {
      // Four position bits is legal and rarely used, and reading the position
      // state a bit too narrowly makes the decoder run off the end of its
      // probability tables partway through.
      final data = XZDecoder().decodeBytes(archiveBytes('pb4.xz'));
      expect(data, equals(pb4Sample()));
    });

    test('decodes an archive written with pb=4 while verifying', testOn: 'vm',
        () {
      final data =
          XZDecoder().decodeBytes(archiveBytes('pb4.xz'), verify: true);
      expect(data, equals(pb4Sample()));
    });

    test('applies the BCJ x86 filter', testOn: 'vm', () {
      final data = XZDecoder().decodeBytes(archiveBytes('x86.xz'));
      expect(data, equals(x86Sample()));
    });

    test('decodes concatenated streams', testOn: 'vm', () {
      // Three separate streams in one file. A decoder that stops after the
      // first one returns only 'one\n', or nothing at all when the first
      // stream is empty, without reporting a failure.
      final data = XZDecoder().decodeBytes(archiveBytes('concatenated.xz'));
      expect(utf8.decode(data), equals('one\ntwo\nthree\n'));
    });

    test('skips stream padding between and after streams', testOn: 'vm', () {
      // Streams may be followed by padding in multiples of four zero bytes.
      final data = XZDecoder().decodeBytes(archiveBytes('stream_padding.xz'));
      expect(utf8.decode(data), equals('one\ntwo\n'));
    });

    test('decodeStream reports success for each of them', testOn: 'vm', () {
      for (final name in [
        'pb4.xz',
        'x86.xz',
        'concatenated.xz',
        'stream_padding.xz',
      ]) {
        final output = OutputMemoryStream();
        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(archiveBytes(name)), output),
            isTrue,
            reason: name);
        expect(output.length, greaterThan(0), reason: name);
      }
    });

    group('match distance', () {
      test('accepts distances up to the declared dictionary', testOn: 'vm', () {
        // Encoded with a 64 KiB dictionary over data whose period is 8 KiB, so
        // the matches reach well past any smaller window. This guards the
        // check below against being too strict.
        final data = XZDecoder().decodeBytes(archiveBytes('long_distance.xz'));
        expect(data.length, equals(4 * 1024 * 1024));
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(archiveBytes('long_distance.xz')),
                OutputMemoryStream()),
            isTrue);
      });

      test('refuses a match that reaches past the declared dictionary',
          testOn: 'vm', () {
        // The same archive with one byte changed: the block header now
        // declares a 4 KiB dictionary, with the header CRC recomputed so the
        // header itself is well formed. The matches still reach 8 KiB back, so
        // xz rejects this file as corrupt and so must this decoder.
        //
        // Accepting it is not only wrong output. The dictionary buffer is
        // larger than the declared dictionary, so an over long distance is
        // remembered, and trimDictionary then moves the write position back
        // below it. The next literal decoded in matched state indexes the
        // dictionary at a negative offset, and that read has its bounds check
        // disabled by a pragma.
        final compressed = archiveBytes('dict_overrun.xz');
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });
    });

    test('accepts a plain List<int> as well as a Uint8List', testOn: 'vm', () {
      // The other overload copies into a Uint8List first, which is a separate
      // path through decodeBytes.
      final asList = archiveBytes('pb4.xz').toList();
      expect(XZDecoder().decodeBytes(asList), equals(pb4Sample()));
    });

    group('decodeBytes throwOnError', () {
      // decodeBytes has no return value to spare for an outcome, so without
      // this a truncated archive is indistinguishable from a whole one.
      Uint8List truncated() {
        final compressed = archiveBytes('long_distance.xz');
        return Uint8List.sublistView(compressed, 0, compressed.length ~/ 2);
      }

      test('stays quiet on a valid archive', testOn: 'vm', () {
        expect(
            XZDecoder().decodeBytes(archiveBytes('pb4.xz'), throwOnError: true),
            equals(pb4Sample()));
        expect(
            XZDecoder().decodeBytes(archiveBytes('pb4.xz'),
                verify: true, throwOnError: true),
            equals(pb4Sample()));
      });

      test('reports a truncated archive that is otherwise silent', testOn: 'vm',
          () {
        final compressed = truncated();

        // The default: partial output, and no way to tell it is partial.
        final quiet = XZDecoder().decodeBytes(compressed);
        expect(quiet, isNotEmpty);
        expect(quiet.length, lessThan(4 * 1024 * 1024));

        expect(() => XZDecoder().decodeBytes(compressed, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('reports it while verifying too', testOn: 'vm', () {
        expect(
            () => XZDecoder()
                .decodeBytes(truncated(), verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('reports a check that does not match', testOn: 'vm', () {
        // Whole and well formed, but the stored CRC64 is wrong, which only a
        // verifying decode notices.
        final compressed = Uint8List.fromList(archiveBytes('crc64.xz'));
        compressed[compressed.length - 21] ^= 0xff;

        // Only the check is broken: the data still decodes.
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isTrue);
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                verify: true),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                verify: true, throwOnError: true),
            throwsA(isA<ArchiveChecksumException>()));

        expect(XZDecoder().decodeBytes(compressed, verify: true),
            XZDecoder().decodeBytes(compressed));
        expect(
            () => XZDecoder()
                .decodeBytes(compressed, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('reports data that is not an archive at all', () {
        expect(
            () => XZDecoder()
                .decodeBytes(utf8.encode('not an archive'), throwOnError: true),
            throwsA(isA<ArchiveException>()));
        expect(XZDecoder().decodeBytes(utf8.encode('not an archive')), isEmpty);
      });

      test('turns a thrown decode failure into the same exception',
          testOn: 'vm', () {
        // Corrupt compressed data makes the LZMA decoder itself throw, which
        // has to surface as an ArchiveException rather than escaping raw.
        final compressed = Uint8List.fromList(archiveBytes('x86.xz'));
        for (var i = 0; i < 64; i++) {
          compressed[400 + i] ^= 0xff;
        }
        expect(() => XZDecoder().decodeBytes(compressed, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });
    });

    group('failure reasons', () {
      // 'Invalid XZ archive' on its own leaves a caller with nowhere to go:
      // a file that is not xz at all, one that lost its tail and one whose
      // checksum does not match all need different answers.
      String reasonFor(Uint8List compressed) {
        try {
          XZDecoder().decodeBytes(compressed, verify: true, throwOnError: true);
          return 'no error';
        } on ArchiveException catch (e) {
          return e.message;
        }
      }

      Uint8List flipped(String name, int offset, [int length = 1]) {
        final data = Uint8List.fromList(archiveBytes(name));
        for (var i = 0; i < length; i++) {
          data[offset + i] ^= 0xff;
        }
        return data;
      }

      test('name the part of the format that was wrong', testOn: 'vm', () {
        final pb4 = archiveBytes('pb4.xz');
        final cases = <String, String>{
          'Invalid XZ stream header signature': reasonFor(
              Uint8List.fromList(utf8.encode('not an archive at all'))),
          'Invalid stream flags': reasonFor(flipped('pb4.xz', 6)),
          'Invalid stream header CRC checksum': reasonFor(flipped('pb4.xz', 8)),
          'Stream footer has invalid index size':
              reasonFor(flipped('pb4.xz', pb4.length - 6)),
          'Invalid XZ stream footer signature':
              reasonFor(flipped('pb4.xz', pb4.length - 1)),
          'CRC64 check failed': reasonFor(
              flipped('crc64.xz', archiveBytes('crc64.xz').length - 21)),
        };
        cases.forEach((expected, actual) {
          expect(actual, contains(expected));
        });

        // Every one of them is distinct, which is the whole point.
        expect(cases.values.toSet(), hasLength(cases.length));
      });

      test('survive being thrown out of the LZMA decoder', testOn: 'vm', () {
        // Some failures arrive as an exception rather than as a rejection, and
        // that text has to reach the caller just the same.
        expect(reasonFor(archiveBytes('dict_overrun.xz')),
            contains('outside the dictionary'));
      });

      test('are not reported when the archive is fine', testOn: 'vm', () {
        expect(reasonFor(archiveBytes('pb4.xz')), equals('no error'));
      });
    });

    group('throwOnError', () {
      test('stays quiet on a valid archive', testOn: 'vm', () {
        final output = OutputMemoryStream();
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(archiveBytes('pb4.xz')), output,
                throwOnError: true),
            isTrue);
        expect(output.getBytes(), equals(pb4Sample()));
      });

      test('turns a refusal into an exception', testOn: 'vm', () {
        // Without it a malformed archive is reported by the return value, and
        // whatever was decoded is left in the output.
        final compressed = Uint8List.fromList(archiveBytes('pb4.xz'));
        compressed[compressed.length - 6] ^= 0xff; // stream footer flags

        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('turns a thrown decode failure into an exception too', testOn: 'vm',
          () {
        // Corrupting the compressed data makes the LZMA decoder itself throw,
        // which has to surface as the same exception rather than escaping raw.
        final compressed = Uint8List.fromList(archiveBytes('x86.xz'));
        for (var i = 0; i < 64; i++) {
          compressed[400 + i] ^= 0xff;
        }

        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });
    });

    group('maxPreallocateSize', () {
      test('caps what uncompressedSize will vouch for', testOn: 'vm', () {
        final compressed = archiveBytes('long_distance.xz');
        final actual = XZDecoder().uncompressedSize(compressed)!;

        // The size in the index comes from the archive, so a decoder that will
        // not act on a number that large declines to report it either.
        expect(
            XZDecoder(maxPreallocateSize: actual - 1)
                .uncompressedSize(compressed),
            isNull);
        expect(
            XZDecoder(maxPreallocateSize: actual).uncompressedSize(compressed),
            equals(actual));
      });

      test('decodes the same bytes on either side of the cap', testOn: 'vm',
          () {
        // Below the cap the buffer is allocated up front from the index; above
        // it the decoder grows the buffer as the bytes arrive. Both have to
        // produce identical output.
        final compressed = archiveBytes('long_distance.xz');
        final reference = XZDecoder().decodeBytes(compressed);
        expect(reference.length, equals(4 * 1024 * 1024));

        for (final cap in [0, 1024, reference.length - 1, reference.length]) {
          expect(XZDecoder(maxPreallocateSize: cap).decodeBytes(compressed),
              equals(reference),
              reason: 'cap $cap');
        }
      });

      test('rejects a negative ceiling', () {
        expect(() => XZDecoder(maxPreallocateSize: -1), throwsArgumentError);
      });

      test('defaults low enough for the platform to survive', () {
        // A failed allocation throws on the VM but kills the page on the web,
        // where dart2wasm cannot reach a gigabyte at all, so the default has to
        // stay well under that there.
        expect(xzDefaultMaxPreallocateSize, greaterThan(0));
        if (identical(1, 1.0)) {
          expect(xzDefaultMaxPreallocateSize,
              lessThanOrEqualTo(512 * 1024 * 1024));
        }
      });
    });

    group('uncompressedSize', () {
      test('agrees with the decoded length', testOn: 'vm', () {
        for (final name in [
          'pb4.xz',
          'x86.xz',
          'concatenated.xz',
          'stream_padding.xz',
          'hello.xz',
          'empty.xz',
          'crc32.xz',
          'crc64.xz',
          'sha256.xz',
          'nocheck.xz',
          'hello-hello-hello.xz',
          'good-1-lzma2-1.xz',
          'cat.jpg.xz',
        ]) {
          final compressed = archiveBytes(name);
          expect(XZDecoder().uncompressedSize(compressed),
              equals(XZDecoder().decodeBytes(compressed).length),
              reason: name);
        }
      });

      test('gives up rather than guessing on data that is not an archive', () {
        expect(XZDecoder().uncompressedSize(Uint8List(0)), isNull);
        expect(XZDecoder().uncompressedSize(utf8.encode('not an archive')),
            isNull);
      });

      test('gives up on a truncated archive', testOn: 'vm', () {
        // The index and footer are what it reads, so losing the tail of the
        // file has to be noticed rather than misread.
        final compressed = archiveBytes('concatenated.xz');
        final truncated =
            Uint8List.sublistView(compressed, 0, compressed.length - 8);
        expect(XZDecoder().uncompressedSize(truncated), isNull);
      });

      test('gives up when the index is corrupt', testOn: 'vm', () {
        final compressed = Uint8List.fromList(archiveBytes('pb4.xz'));
        // Land in the index, which sits just before the twelve byte footer.
        compressed[compressed.length - 16] ^= 0xff;
        expect(XZDecoder().uncompressedSize(compressed), isNull);
      });
    });
  });
}

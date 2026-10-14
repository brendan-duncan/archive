import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The chunked decoder is the pull decoder turned inside out, so what it must
// do is agree with it on every archive whatever the input is cut into. The
// archives are the ones the pull decoder is already tested against

Uint8List _archive(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

Uint8List _decode(Uint8List src, int piece, {bool verify = true}) {
  final held = _Held();
  final decoder = XzChunkedDecoder(held, verify: verify);
  for (var at = 0; at < src.length; at += piece) {
    final end = at + piece < src.length ? at + piece : src.length;
    decoder.add(Uint8List.sublistView(src, at, end));
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  const archives = [
    'cat.jpg.xz',
    'concatenated.xz',
    'crc32.xz',
    'crc64.xz',
    'empty.xz',
    'good-1-lzma2-1.xz',
    'good-1-lzma2-4.xz',
    'hello.xz',
    'hello-hello-hello.xz',
    'long_distance.xz',
    'nocheck.xz',
    'pb4.xz',
    'sha256.xz',
    'stream_padding.xz',
    'x86.xz',
  ];

  group('xz chunked decoder', () {
    for (final name in archives) {
      test('$name decodes same in pieces of any size', testOn: 'vm', () {
        final src = _archive(name);
        final want =
            XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
        for (final piece in [1, 2, 7, 64, 1024, 1 << 16, src.length + 1]) {
          expect(_decode(src, piece), want, reason: 'piece size $piece');
        }
      });
    }

    // 7-Zip writes an uncompressed chunk with control 2, then an LZMA chunk that
    // resets nothing. That LZMA chunk keeps the state and probabilities from
    // before the copy. The archive is LZMA with reset 3, control 2, LZMA with
    // reset 0. It was built by hand and passes xz -t and 7zz t
    test('LZMA chunk after uncompressed chunk keeps decoder state',
        testOn: 'vm', () async {
      final src = _archive('lzma2_copy_keeps_state.xz');
      final want = List.filled(
              20, 'the quick brown fox jumps over the lazy dog 0123456789\n')
          .join()
          .codeUnits
          .sublist(0, 900);
      expect(
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true), want);
      expect(xzCodec.decode(src), want);
      for (final piece in [1, 7, 64]) {
        expect(_decode(src, piece), want, reason: 'piece size $piece');
      }
      final threaded = <int>[];
      await for (final piece in Stream<List<int>>.value(src).transform(
          const XzCodec(multithread: XZMultithreadOptions.converter(workers: 2))
              .decoder)) {
        threaded.addAll(piece);
      }
      expect(threaded, want);
    });

    // From the xz 5.8.3 test suite, and xz -t rejects every one. The LZMA2 ones
    // decode an LZMA chunk with no properties set after a dictionary reset.
    // bad-1-vli-1.xz writes a length in two bytes where one is enough
    for (final name in [
      'bad-1-lzma2-4.xz',
      'bad-1-lzma2-5.xz',
      'bad-1-lzma2-8.xz',
      'bad-1-vli-1.xz',
    ]) {
      test('$name throws on every decode path', testOn: 'vm', () {
        final src = _archive(name);
        expect(
            () =>
                XZDecoder().decodeBytes(src, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        expect(() => xzCodec.decode(src), throwsA(isA<ArchiveException>()));
        expect(() => _decode(src, 7), throwsA(isA<ArchiveException>()));
      });
    }

    test('truncated archive throws ArchiveException', testOn: 'vm', () {
      final src = _archive('good-1-lzma2-1.xz');
      expect(() => _decode(Uint8List.sublistView(src, 0, src.length - 8), 64),
          throwsA(isA<ArchiveException>()));
    });

    test('overlong index record count throws ArchiveException', () {
      final encoded = XZEncoder().encodeBytes([]);
      encoded[13] = 0x80;
      ByteData.sublistView(encoded)
          .setUint32(16, getCrc32(encoded.sublist(12, 16)), Endian.little);
      expect(
          () => XZDecoder()
              .decodeBytes(encoded, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      for (final piece in [1, encoded.length]) {
        expect(() => _decode(encoded, piece), throwsA(isA<ArchiveException>()),
            reason: 'piece size $piece');
      }
    });

    test('first LZMA2 chunk without dictionary reset throws', () {
      final encoded = XZEncoder().encodeBytes([1, 2, 3], check: XZCheck.crc32);
      expect(encoded[24], 1);
      encoded[24] = 2;
      expect(() => xzCodec.decode(encoded), throwsA(isA<ArchiveException>()));
    });

    for (final field in [
      'stream flags',
      'block flags',
      'LZMA2 property size'
    ]) {
      test('unsupported $field with valid checksums throws', () {
        final encoded =
            XZEncoder().encodeBytes([65, 66, 67], check: XZCheck.none);
        final view = ByteData.sublistView(encoded);
        // Recompute the checks so only the unsupported field can reject this
        if (field == 'stream flags') {
          encoded[7] |= 0x10;
          encoded[encoded.length - 3] |= 0x10;
          view.setUint32(8, getCrc32(encoded.sublist(6, 8)), Endian.little);
          view.setUint32(
              encoded.length - 12,
              getCrc32(encoded.sublist(encoded.length - 8, encoded.length - 2)),
              Endian.little);
        } else {
          if (field == 'block flags') {
            encoded[13] |= 4;
          } else {
            expect(encoded[14], 0x21);
            expect(encoded[15], 1);
            encoded[15] = 2;
          }
          final headerLength = (encoded[12] + 1) * 4;
          view.setUint32(
              12 + headerLength - 4,
              getCrc32(encoded.sublist(12, 12 + headerLength - 4)),
              Endian.little);
        }
        for (final piece in [1, encoded.length]) {
          expect(
              () => _decode(encoded, piece), throwsA(isA<ArchiveException>()),
              reason: 'piece size $piece');
        }
      });
    }

    // The input may stop sending without closing: what arrived whole is not
    // held back for the close, and what cannot be xz is refused at once
    test('complete archive is decoded before input closes', () async {
      final source = StreamController<List<int>>();
      final content = List<int>.generate(3000, (i) => (i * 7) & 0xff);
      final got = <int>[];
      final arrived = Completer<void>();
      final subscription =
          source.stream.transform(xzCodec.decoder).listen((piece) {
        got.addAll(piece);
        if (got.length >= content.length && !arrived.isCompleted) {
          arrived.complete();
        }
      });
      source.add(XZEncoder().encodeBytes(content));
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(got, content);
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('bytes that cannot start archive fail stream before input closes',
        () async {
      final source = StreamController<List<int>>();
      final failed = Completer<Object>();
      final subscription = source.stream
          .transform(xzCodec.decoder)
          .listen((_) {}, onError: failed.complete);
      source.add([0xfd, 0x37, 0x7b]);
      expect(await failed.future.timeout(const Duration(seconds: 5)),
          isA<ArchiveException>());
      await subscription.cancel();
      await source.close();
    });

    test('start of magic waits for more input instead of failing', () async {
      final source = StreamController<List<int>>();
      Object? error;
      final ended = Completer<void>();
      source.stream.transform(xzCodec.decoder).listen((_) {},
          onError: (Object e) {
        error = e;
        if (!ended.isCompleted) {
          ended.complete();
        }
      }, onDone: () {
        if (!ended.isCompleted) {
          ended.complete();
        }
      });
      source.add([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0, 0]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(error, isNull);
      await source.close();
      await ended.future.timeout(const Duration(seconds: 5));
      expect(error, isA<ArchiveException>());
    });

    test('damaged block throws on check mismatch', testOn: 'vm', () {
      final src = Uint8List.fromList(_archive('crc32.xz'));
      src[src.length - 20] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });

    test('add after close throws StateError, as dart:io filters do',
        testOn: 'vm', () {
      final src = _archive('hello.xz');
      final decoder = XzChunkedDecoder(_Held())
        ..add(src)
        ..close();
      expect(() => decoder.add(src), throwsStateError);
    });

    test('failed sink throws same error on every later call', testOn: 'vm', () {
      final decoder = XzChunkedDecoder(_Held(), verify: true);
      // Not an xz signature, which the first piece is enough to know
      expect(
          () => decoder.add(Uint8List(64)), throwsA(isA<ArchiveException>()));
      // What follows is not read as if the failure had not happened
      expect(() => decoder.add(_archive('hello.xz')),
          throwsA(isA<ArchiveException>()));
      expect(decoder.close, throwsA(isA<ArchiveException>()));
    });

    test('check is verified unless verify is false', testOn: 'vm', () {
      // The eight bytes of the CRC64 sit between the block and the index, so
      // damaging one of them leaves data only the check can call wrong
      final src = Uint8List.fromList(_archive('cat.jpg.xz'));
      src[src.length - 28] ^= 0xff;
      final held = _Held();
      // The default verifies, which is the only chance a stream reader gets
      expect(
          () => XzChunkedDecoder(held)
            ..add(src)
            ..close(),
          throwsA(isA<ArchiveException>()));
      expect(() {
        XzChunkedDecoder(_Held(), verify: false)
          ..add(src)
          ..close();
      }, returnsNormally);
    });

    test('addSlice decodes range and closes on isLast', testOn: 'vm', () {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final held = _Held();
      final decoder = XzChunkedDecoder(held);
      const piece = 700;
      for (var at = 0; at < src.length; at += piece) {
        final end = at + piece < src.length ? at + piece : src.length;
        decoder.addSlice(src, at, end, end == src.length);
      }
      expect(held.closed, isTrue);
      expect(held.bytes, want);
    });

    // The pull decoder is what this has to agree with, so the agreement is
    // checked on every truncation and every single byte change of an archive,
    // rather than on the handful of ways one imagines it could go wrong
    for (final name in const [
      'empty.xz',
      'hello.xz',
      'crc32.xz',
      'crc64.xz',
      'nocheck.xz',
      'sha256.xz',
      'pb4.xz',
      'stream_padding.xz',
      'hello-hello-hello.xz',
    ]) {
      test('$name damaged any way gives same result as XZDecoder', testOn: 'vm',
          () {
        final base = _archive(name);
        void agree(Uint8List src, String what) {
          Uint8List? pull;
          try {
            pull =
                XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
          } catch (_) {
            pull = null;
          }
          for (final piece in const [1, 13, 4096]) {
            Uint8List? chunked;
            try {
              chunked = _decode(src, piece);
            } catch (_) {
              chunked = null;
            }
            expect(chunked != null, pull != null,
                reason: '$what, piece $piece: one took it and the other did '
                    'not');
            if (pull != null && chunked != null) {
              expect(chunked, pull, reason: '$what, piece $piece');
            }
          }
        }

        for (var length = 0; length <= base.length; length++) {
          agree(Uint8List.sublistView(base, 0, length), 'cut at $length');
        }
        for (var at = 0; at < base.length; at++) {
          final src = Uint8List.fromList(base);
          src[at] ^= 0xff;
          agree(src, 'byte $at flipped');
        }
      });
    }

    test('empty input throws ArchiveException', () {
      expect(() => XzChunkedDecoder(_Held()).close(),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('xz stream converter', () {
    test('default encoder writes CRC64 check on every platform', () {
      final native = base64Decode(
          '/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQACAQIDAACjq/XzQTeKOwABGwMLL7kQ'
          'H7bzfQEAAAAABFla');
      expect(xzCodec.encode([1, 2, 3]), native);
    });

    for (final name in ['cat.jpg.xz', 'concatenated.xz', 'x86.xz', 'pb4.xz']) {
      test('$name read from file in reader pieces decodes', testOn: 'vm',
          () async {
        final want = XZDecoder()
            .decodeBytes(_archive(name), verify: true, throwOnError: true);
        final got = <int>[];
        // openRead hands over whatever the file system gave it, when it gave
        // it, which is the arrival a caller actually has
        await for (final piece in File(p.join('test/_data/xz', name))
            .openRead()
            .transform(xzCodec.decoder)) {
          got.addAll(piece);
        }
        expect(got, want);
      });
    }

    test('pieces arriving in separate events decode same', testOn: 'vm',
        () async {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final random = Random(20260910);
      final controller = StreamController<List<int>>();
      final done = controller.stream
          .transform(xzCodec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      var at = 0;
      while (at < src.length) {
        final take = 1 + random.nextInt(3000);
        final end = at + take < src.length ? at + take : src.length;
        // A real source yields between events, which is where a decoder that
        // held state on the stack rather than in fields would come apart
        await Future<void>.delayed(Duration.zero);
        controller.add(Uint8List.sublistView(src, at, end));
        at = end;
      }
      await controller.close();
      expect(await done, want);
    });

    test('paused listener receives all output after resume', testOn: 'vm',
        () async {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final got = <int>[];
      final finished = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      var paused = false;
      subscription = File(p.join('test/_data/xz', 'cat.jpg.xz'))
          .openRead()
          .transform(xzCodec.decoder)
          .listen((piece) {
        got.addAll(piece);
        if (!paused) {
          paused = true;
          subscription.pause();
          unawaited(Future<void>.delayed(const Duration(milliseconds: 20))
              .then((_) => subscription.resume()));
        }
      }, onDone: finished.complete);
      await finished.future;
      expect(got, want);
    });

    test('output is sent while input still arrives, not at end', testOn: 'vm',
        () async {
      // Forty copies of the same archive is a valid xz file of forty streams,
      // which is what gives a long input with something to hand over all the
      // way through it
      final one = _archive('cat.jpg.xz');
      final src = Uint8List(one.length * 40);
      for (var i = 0; i < 40; i++) {
        src.setRange(i * one.length, (i + 1) * one.length, one);
      }
      final want = XZDecoder().decodeBytes(one, verify: true).length * 40;

      final controller = StreamController<List<int>>();
      var fed = 0;
      var decoded = 0;
      var fedAtFirstOutput = -1;
      var decodedWhenFedOut = 0;
      final finished = Completer<void>();
      controller.stream.transform(xzCodec.decoder).listen((piece) {
        if (fedAtFirstOutput < 0) {
          fedAtFirstOutput = fed;
        }
        decoded += piece.length;
      }, onDone: finished.complete);

      // Pieces the size a socket hands over, one event apart, which is the
      // shape of a download rather than of a buffer that is already full
      const piece = 16 << 10;
      for (var at = 0; at < src.length; at += piece) {
        final end = at + piece < src.length ? at + piece : src.length;
        controller.add(Uint8List.sublistView(src, at, end));
        fed = end;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      decodedWhenFedOut = decoded;
      await controller.close();
      await finished.future;

      expect(decoded, want);
      // Something came out long before the input ran out
      expect(fedAtFirstOutput, lessThan(src.length ~/ 5));
      // And most of it was already out by the time the last piece arrived,
      // which is what a decoder that held the archive could not do
      expect(decodedWhenFedOut, greaterThan((want * 0.9).round()));
    });

    test('convert decodes whole archive in one call', testOn: 'vm', () {
      final src = _archive('hello.xz');
      expect(const XzDecoderConverter(verify: true).convert(src),
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true));
    });

    test('failure is sent to stream as error event', testOn: 'vm', () async {
      final src = _archive('good-1-lzma2-1.xz');
      final cut = Uint8List.sublistView(src, 0, src.length ~/ 2);
      expect(
          Stream<List<int>>.fromIterable([cut])
              .transform(xzCodec.decoder)
              .toList(),
          throwsA(isA<ArchiveException>()));
    });

    // xz 5.8 refuses an LZMA chunk whose first range coder byte is not zero
    test('range coder not starting at zero throws', testOn: 'vm', () {
      final src = Uint8List.fromList(_archive('good-1-lzma2-1.xz'));
      final chunk = 12 + (src[12] + 1) * 4;
      expect(src[chunk], greaterThanOrEqualTo(0xe0));
      src[chunk + 6] ^= 0x01;
      expect(() => xzCodec.decode(src), throwsA(isA<ArchiveException>()));
      expect(
          () => XZDecoder().decodeBytes(src, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('nonzero range coder start throws even with verify false',
        testOn: 'vm', () {
      final src = Uint8List.fromList(_archive('hello-hello-hello.xz'));
      final chunk = 12 + (src[12] + 1) * 4;
      expect(src[chunk], greaterThanOrEqualTo(0xe0));
      src[chunk + 6] = 177;
      expect(() => XZDecoder().decodeBytes(src, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          () => XZDecoder().decodeStream(
              InputMemoryStream(src), OutputMemoryStream(),
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(() => const XzCodec(verify: false).decode(src),
          throwsA(isA<ArchiveException>()));
      for (final piece in [1, 13, 4096]) {
        expect(() => _decode(src, piece, verify: false),
            throwsA(isA<ArchiveException>()),
            reason: 'piece $piece');
      }
      expect(XZDecoder().decodeBytes(src), isEmpty);
      final output = OutputMemoryStream();
      expect(XZDecoder().decodeStream(InputMemoryStream(src), output), isFalse);
      expect(output.getBytes(), isEmpty);
    });

    test('wrong SHA-256 check throws ArchiveException', testOn: 'vm', () {
      final src = Uint8List.fromList(_archive('sha256.xz'));
      expect(src[7], 0x0a);
      final data = 12 + (src[12] + 1) * 4 + 3;
      expect(
          utf8.decode(Uint8List.sublistView(src, data, data + 6)), 'hello\n');
      src[data] ^= 0x01;
      expect(() => xzCodec.decode(src), throwsA(isA<ArchiveException>()));
    });
  });
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;
  var closed = false;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

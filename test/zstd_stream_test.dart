@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The chunked decoder is the frame decoder turned inside out, so what it has to
// do is agree with it on every archive whatever the input is cut into. The
// archives are the ones the whole-input decoder is already tested against.

final _directory = Directory('test/_data/zstd');

Uint8List _archive(String name) =>
    File(p.join(_directory.path, name)).readAsBytesSync();

List<String> _archives() => _directory
    .listSync()
    .whereType<File>()
    .map((f) => f.uri.pathSegments.last)
    .where((name) => name.endsWith('.zst'))
    .toList()
  ..sort();

Uint8List _decode(Uint8List src, int piece,
    {bool verify = true, ZstdDictionary? dictionary}) {
  final held = _Held();
  final decoder =
      ZstdChunkedDecoder(held, verify: verify, dictionary: dictionary);
  for (var at = 0; at < src.length; at += piece) {
    final end = at + piece < src.length ? at + piece : src.length;
    decoder.addSlice(src, at, end, false);
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  final dictionaries = {
    'raw': ZstdDictionary(_archive('dict-raw.dict')),
    'trained': ZstdDictionary(_archive('dict-trained.dict')),
  };

  ZstdDictionary? dictionaryFor(String name) {
    if (name.startsWith('dv-') || name.contains('-dict')) {
      return name.contains('raw')
          ? dictionaries['raw']
          : dictionaries['trained'];
    }
    return null;
  }

  group('zstd chunked decoder', () {
    for (final name in _archives()) {
      test('$name decodes same in pieces of any size', () {
        final src = _archive(name);
        final dictionary = dictionaryFor(name);
        Uint8List? want;
        try {
          want = ZstdDecoder.withDictionary(dictionary)
              .decodeBytes(src, verify: true, throwOnError: true);
        } catch (_) {
          want = null;
        }
        for (final piece in [1, 3, 64, 4096, 1 << 16, src.length + 1]) {
          Uint8List? got;
          try {
            got = _decode(src, piece, dictionary: dictionary);
          } catch (_) {
            got = null;
          }
          expect(got != null, want != null, reason: 'piece $piece');
          if (want != null && got != null) {
            expect(got, want, reason: 'piece $piece');
          }
        }
      });
    }

    test('truncated frame throws ArchiveException', () {
      final src = _archive('text-1k-l19.zst');
      expect(() => _decode(Uint8List.sublistView(src, 0, src.length - 6), 64),
          throwsA(isA<ArchiveException>()));
    });

    test('trailing empty skippable frame is accepted', () {
      final content = [1, 2, 3];
      final archive = Uint8List.fromList([
        ...ZstdEncoder().encodeBytes(content),
        0x50,
        0x2a,
        0x4d,
        0x18,
        0,
        0,
        0,
        0,
      ]);
      expect(ZstdDecoder().decodeBytes(archive, throwOnError: true), content);
      expect(_decode(archive, archive.length), content);
    });

    final skippableOnly = <String, List<int>>{
      'empty': [0x50, 0x2a, 0x4d, 0x18, 0, 0, 0, 0],
      'payload': [0x5f, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3],
      'multiple': [
        0x50,
        0x2a,
        0x4d,
        0x18,
        0,
        0,
        0,
        0,
        0x5f,
        0x2a,
        0x4d,
        0x18,
        1,
        0,
        0,
        0,
        7,
      ],
    };
    for (final entry in skippableOnly.entries) {
      test('${entry.key} archive of only skippable frames decodes to no bytes',
          () {
        final archive = Uint8List.fromList(entry.value);
        expect(ZstdDecoder().decodeBytes(archive, throwOnError: true), isEmpty);
        for (final piece in [1, 3, archive.length]) {
          expect(_decode(archive, piece), isEmpty);
        }
      });
      test(
          '${entry.key} archive of only skippable frames decodes through InputStream',
          () {
        final output = OutputMemoryStream();
        expect(
            ZstdDecoder().decodeStream(InputMemoryStream(entry.value), output,
                verify: true, throwOnError: true),
            isTrue);
        expect(output.getBytes(), isEmpty);
      });
    }

    // The input may stop sending without closing: what arrived whole is not
    // held back for the close, and what cannot be zstd is refused at once
    test('complete frame is decoded before input closes', () async {
      final source = StreamController<List<int>>();
      final content = List<int>.generate(3000, (i) => (i * 7) & 0xff);
      final got = <int>[];
      final arrived = Completer<void>();
      final subscription =
          source.stream.transform(zstdCodec.decoder).listen((piece) {
        got.addAll(piece);
        if (got.length >= content.length && !arrived.isCompleted) {
          arrived.complete();
        }
      });
      source.add(ZstdEncoder().encodeBytes(content));
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(got, content);
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    });

    // A frame that has not ended still hands out every block that arrived
    // whole. Only the last block waits for the bytes it lacks
    test('blocks are decoded before frame ends', () async {
      final source = StreamController<List<int>>();
      final content =
          List<int>.generate(1500000, (i) => (i * 7 + (i >> 9)) & 0xff);
      final frame = ZstdEncoder().encodeBytes(content);
      final got = <int>[];
      final arrived = Completer<void>();
      final subscription =
          source.stream.transform(zstdCodec.decoder).listen((piece) {
        got.addAll(piece);
        if (got.length >= content.length - (128 << 10) &&
            !arrived.isCompleted) {
          arrived.complete();
        }
      });
      source.add(Uint8List.sublistView(frame, 0, frame.length - 8));
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(got, content.sublist(0, got.length));
      await subscription.cancel();
      await source.close();
    });

    for (final junk in [
      [0x27],
      [0x28, 0xb5, 0x2e],
      [0x53, 0x2a, 0x4c],
    ]) {
      test('$junk cannot start frame and fails stream before input closes',
          () async {
        final source = StreamController<List<int>>();
        final failed = Completer<Object>();
        final subscription = source.stream
            .transform(zstdCodec.decoder)
            .listen((_) {}, onError: failed.complete);
        source.add(junk);
        expect(await failed.future.timeout(const Duration(seconds: 5)),
            isA<ArchiveException>());
        await subscription.cancel();
        await source.close();
      });
    }

    for (final start in [
      [0x28, 0xb5, 0x2f],
      [0x5f, 0x2a],
    ]) {
      test('$start may begin frame, decoder waits for more input', () async {
        final source = StreamController<List<int>>();
        Object? error;
        final ended = Completer<void>();
        source.stream.transform(zstdCodec.decoder).listen((_) {},
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
        source.add(start);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(error, isNull);
        await source.close();
        await ended.future.timeout(const Duration(seconds: 5));
        expect(error, isA<ArchiveException>());
      });
    }

    test('damaged frame throws on checksum mismatch', () {
      final src = Uint8List.fromList(_archive('text-1k-l19.zst'));
      src[src.length - 12] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });

    test('checksum is verified unless verify is false', () {
      final src = Uint8List.fromList(_archive('text-1k-l19.zst'));
      // The last four bytes are the frame's XXH64, which only the check reads
      src[src.length - 1] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
      expect(() => _decode(src, 64, verify: false), returnsNormally);
    });

    test('empty input throws ArchiveException', () {
      expect(() => ZstdChunkedDecoder(_Held()).close(),
          throwsA(isA<ArchiveException>()));
    });

    test('frame with dictionary id throws without dictionary', () {
      final src = _archive('dv-small-trained-l1.zst');
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });
  });

  group('zstd stream converter', () {
    test('levels above 19 of unknown size need ultra, as zstd --ultra does',
        testOn: 'vm', () async {
      final source = Uint8List.fromList(
          List.generate(20000, (i) => (i * 7 + (i >> 9)) % 251));
      Future<List<int>> encode(Converter<List<int>, List<int>> encoder) =>
          Stream<List<int>>.value(source)
              .transform(encoder)
              .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      final plain = await encode(const ZstdEncoderConverter(level: 19));
      for (final level in [20, 22, 30]) {
        expect(await encode(ZstdEncoderConverter(level: level)), plain,
            reason: 'level $level');
      }
      expect(await encode(const ZstdCodec(level: 20).encoder), plain);
      final ultra =
          await encode(const ZstdEncoderConverter(level: 20, ultra: true));
      expect(ultra, isNot(plain));
      expect(
          await encode(const ZstdCodec(level: 20, ultra: true).encoder), ultra);
      expect(
          await encode(
              ZstdEncoderConverter(level: 20, contentSize: source.length)),
          await encode(ZstdEncoderConverter(
              level: 20, contentSize: source.length, ultra: true)));
      const workers = ZstdMultithreadOptions<Object?>.converter(workers: 2);
      expect(
          await encode(
              const ZstdEncoderConverter(level: 20, multithread: workers)),
          await encode(
              const ZstdEncoderConverter(level: 19, multithread: workers)));
    });

    test('empty stream gives reference frame', () async {
      final frame = await const Stream<List<int>>.empty()
          .transform(const ZstdCodec(level: 1, frameChecksum: false).encoder)
          .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      expect(frame, [0x28, 0xb5, 0x2f, 0xfd, 0x20, 0, 1, 0, 0]);
    });

    test('file read in reader pieces decodes', () async {
      final name = 'domains-slice-l19.zst';
      final want = ZstdDecoder()
          .decodeBytes(_archive(name), verify: true, throwOnError: true);
      final got = <int>[];
      await for (final piece in File(p.join(_directory.path, name))
          .openRead()
          .transform(zstdCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, want);
    });

    test('pieces arriving in separate events decode same', () async {
      final src = _archive('domains-slice-l19.zst');
      final want = ZstdDecoder().decodeBytes(src, verify: true);
      final controller = StreamController<List<int>>();
      final done = controller.stream
          .transform(zstdCodec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      for (var at = 0; at < src.length; at += 700) {
        final end = at + 700 < src.length ? at + 700 : src.length;
        await Future<void>.delayed(Duration.zero);
        controller.add(Uint8List.sublistView(src, at, end));
      }
      await controller.close();
      expect(await done, want);
    });

    test('convert decodes whole archive in one call', () {
      final src = _archive('text-1k-l19.zst');
      expect(zstdCodec.decode(src), ZstdDecoder().decodeBytes(src));
    });

    test('Stream encodes and decodes back through zstdCodec converters',
        () async {
      final source = Uint8List(300000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 13 + (i >> 9)) & 0xff;
      }
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 8192) {
        final end = at + 8192 < source.length ? at + 8192 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final got = <int>[];
      await for (final piece in Stream<List<int>>.fromIterable(pieces)
          .transform(zstdCodec.encoder)
          .transform(zstdCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, source);
    });

    test('input piece sizes do not change output', () {
      final source = Uint8List(400000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 29 + (i >> 7)) & 0xff;
      }
      Uint8List encode(int piece,
          {required int level, required bool checksum}) {
        final held = _Held();
        final encoder =
            ZstdChunkedEncoder(held, level: level, checksum: checksum);
        for (var at = 0; at < source.length; at += piece) {
          final end = at + piece < source.length ? at + piece : source.length;
          encoder.addSlice(source, at, end, false);
        }
        encoder.close();
        return held.bytes;
      }

      for (final level in [1, 3, 6, 9, 12, 17, 22]) {
        for (final checksum in [true, false]) {
          final whole = encode(source.length, level: level, checksum: checksum);
          for (final piece in [1, 17, 4096, 65536, 131072]) {
            expect(encode(piece, level: level, checksum: checksum), whole,
                reason: 'level $level checksum $checksum piece $piece');
          }
          expect(
              ZstdDecoder()
                  .decodeBytes(whole, verify: true, throwOnError: true),
              source,
              reason: 'level $level checksum $checksum');
        }
      }
    });

    test('double-fast matches stay inside window after input ring wraps', () {
      const block = 131072;
      const ring = (1 << 21) + block;
      final source = Uint8List(ring + block);
      var state = 937;
      for (var i = 0; i < source.length; i++) {
        state = (state * 1664525 + 1013904223) & 0xffffffff;
        source[i] = state >> 24;
      }
      source.setRange(ring + 100, source.length, source, 2 * block - 100);

      for (final level in [3, 4]) {
        final held = _Held();
        final encoder = ZstdChunkedEncoder(held, level: level, checksum: false);
        for (var at = 0; at < source.length; at += 65536) {
          encoder.addSlice(source, at, at + 65536, false);
        }
        encoder.close();
        final archive = held.bytes;
        expect(ZstdDecoder().decodeBytes(archive, throwOnError: true), source,
            reason: 'level $level');
        // ZSTD_compressStream2 retains 200 literals before this boundary match
        expect(
            archive.sublist(ring + 6 + 3 * 17),
            [
              0xa4,
              0x06,
              0x00,
              0x84,
              0x0c,
              ...source.sublist(ring, ring + 200),
              0x01,
              0x00,
              0xc8,
              0x9a,
              0xff,
              0x65,
              0x00,
              0xcf,
              0x9b,
              0x14,
              0x01,
              0x00,
              0x00,
            ],
            reason: 'level $level');
      }
    });

    test('output of every level decodes back', () {
      final source = Uint8List(200000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 5 + (i >> 6)) & 0xff;
      }
      for (var level = 1; level <= 22; level++) {
        final held = _Held();
        final encoder = ZstdChunkedEncoder(held, level: level);
        for (var at = 0; at < source.length; at += 33333) {
          final end = at + 33333 < source.length ? at + 33333 : source.length;
          encoder.addSlice(source, at, end, false);
        }
        encoder.close();
        expect(
            ZstdDecoder()
                .decodeBytes(held.bytes, verify: true, throwOnError: true),
            source,
            reason: 'level $level');
      }
    });

    test('empty input writes valid frame', () {
      final held = _Held();
      ZstdChunkedEncoder(held).close();
      expect(held.closed, isTrue);
      expect(
          ZstdDecoder()
              .decodeBytes(held.bytes, verify: true, throwOnError: true),
          isEmpty);
    });

    test('output has no content size and decodes back', () {
      final source = Uint8List(70000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 7) & 0xff;
      }
      for (final level in [1, 3, 9, 19]) {
        for (final piece in [1, 4096, 65536, source.length]) {
          final held = _Held();
          final encoder = ZstdChunkedEncoder(held, level: level);
          for (var at = 0; at < source.length; at += piece) {
            final end = at + piece < source.length ? at + piece : source.length;
            encoder.addSlice(source, at, end, false);
          }
          encoder.close();
          final archive = held.bytes;
          // A frame that names no size says so in its descriptor
          expect(archive[4] >> 6, 0, reason: 'level $level piece $piece');
          expect((archive[4] >> 5) & 1, 0, reason: 'level $level piece $piece');
          expect(
              ZstdDecoder()
                  .decodeBytes(archive, verify: true, throwOnError: true),
              source,
              reason: 'level $level piece $piece');
        }
      }
    });

    // Tests cannot run zstd, so fixtures in pledged/ are made by hand from
    // source below: st-* with `zstd --single-thread -L --stream-size=N` and
    // mt-* with `zstd -T2 -3 --stream-size=3145728`
    Uint8List pledgedSource(int size) {
      final source = Uint8List(size);
      for (var i = 0; i < size; i++) {
        source[i] = (i * 13 + (i >> 9)) & 0xff;
      }
      return source;
    }

    test('contentSize gives reference output for pledged size', () {
      for (final size in [1, 255, 256, 65792, 300000]) {
        final source = pledgedSource(size);
        for (final level in [1, 3, 19]) {
          final want = _archive('pledged/st-$size-l$level.zst');
          for (final piece in [777, 65536]) {
            final held = _Held();
            final encoder =
                ZstdChunkedEncoder(held, level: level, contentSize: size);
            for (var at = 0; at < size; at += piece) {
              encoder.addSlice(
                  source, at, at + piece < size ? at + piece : size, false);
            }
            encoder.close();
            final reason = 'size $size level $level piece $piece';
            expect(held.bytes, want, reason: reason);
            expect(ZstdDecoder().uncompressedSize(held.bytes), size,
                reason: reason);
          }
        }
      }
    });

    test('contentSize through threaded converter gives reference output',
        () async {
      Future<List<int>> encode(Uint8List source, int level) =>
          Stream<List<int>>.fromIterable([
            for (var at = 0; at < source.length; at += 65536)
              Uint8List.sublistView(source, at,
                  at + 65536 < source.length ? at + 65536 : source.length)
          ])
              .transform(ZstdEncoderConverter(
                  level: level,
                  contentSize: source.length,
                  multithread:
                      const ZstdMultithreadOptions.converter(workers: 2)))
              .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));

      expect(await encode(pledgedSource(3145728), 3),
          _archive('pledged/mt-3145728-l3.zst'));
      expect(await encode(pledgedSource(300000), 19),
          _archive('pledged/st-300000-l19.zst'));
    });

    test('input length different from contentSize throws', () async {
      final source = Uint8List(1000);
      for (final given in [0, 999, 1001]) {
        expect(() => ZstdEncoderConverter(contentSize: given).convert(source),
            throwsA(isA<ArchiveException>()),
            reason: 'contentSize $given');
        expect(
            Stream<List<int>>.value(source)
                .transform(ZstdEncoderConverter(
                    contentSize: given,
                    multithread:
                        const ZstdMultithreadOptions.converter(workers: 2)))
                .drain<void>(),
            throwsA(isA<ArchiveException>()),
            reason: 'threaded contentSize $given');
      }
      expect(() => ZstdEncoderConverter(contentSize: 1).convert(Uint8List(0)),
          throwsA(isA<ArchiveException>()));
      expect(ZstdEncoderConverter(contentSize: 0).convert(Uint8List(0)),
          const ZstdEncoderConverter().convert(Uint8List(0)));
      expect(() => ZstdChunkedEncoder(_Held(), contentSize: -1),
          throwsArgumentError);
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

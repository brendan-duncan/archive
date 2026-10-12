import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/bzip2/bzip2_chunked.dart' show Bz2MarkerScan;
import 'package:test/test.dart';

// bzip2 is a bit stream: a block starts wherever the last one ended, not on a
// byte boundary, and carries no length. So the chunked decoder has to find the
// marker that ends a block before it can decode it, and the thing to check is
// that where the input is cut makes no difference to what comes out.

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state =
        (state * 20077 + state * 16838 % 0x8000 * 0x10000 + 12345) % 0x80000000;
    // Runs of one byte, which is what the format's own run coding is for
    bytes[i] = (state >> 16) % 7 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Uint8List _encode(Uint8List source, int piece, {int blockSize100k = 9}) {
  final held = _Held();
  final encoder = BZip2ChunkedEncoder(held, blockSize100k: blockSize100k);
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    encoder.addSlice(source, at, end, false);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

Uint8List _decode(Uint8List archive, int piece, {bool verify = true}) {
  final held = _Held();
  final decoder = BZip2ChunkedDecoder(held, verify: verify);
  for (var at = 0; at < archive.length; at += piece) {
    final end = at + piece < archive.length ? at + piece : archive.length;
    decoder.addSlice(archive, at, end, false);
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  // A real archive with a marker inside its data takes about 2^48 tries, so the
  // scan is tested on bits built here
  group('bzip2 marker scan', () {
    Uint8List bits(Map<int, int> markers) {
      final out = Uint8List(64);
      markers.forEach((at, marker) {
        var rest = marker;
        for (var i = 47; i >= 0; i--) {
          final bit = at + i;
          out[bit >> 3] |= (rest % 2) << (7 - (bit & 7));
          rest ~/= 2;
        }
      });
      return out;
    }

    const block = 0x314159265359;
    const end = 0x177245385090;

    test('finds marker at scan start position', () {
      final scan = Bz2MarkerScan()..start(10);
      expect(scan.locate(bits({10: end}), 64), isTrue);
      expect(scan.position, 58);
    });

    test('finds next marker right after previous one', () {
      final scan = Bz2MarkerScan()..start(10);
      final bytes = bits({10: block, 58: end});
      expect(scan.locate(bytes, 64), isTrue);
      expect(scan.position, 58);
      expect(scan.locate(bytes, 64), isTrue);
      expect(scan.position, 106);
    });
  });

  group('bzip2 chunked decoder', () {
    test('marker bits in unused selectors do not end block', () {
      // The extra selectors contain a block marker before the Huffman tables
      final archive = base64Decode(
          'QlpoOTFBWSZTWUT3E3gAAAGRgEAABkSQgDADwxQVkmU1kQGaQhgQQwIbaBVCeLuSKcKEgie4m8AA');
      final source = 'hello world'.codeUnits;
      expect(BZip2Decoder().decodeBytes(archive, verify: true), source);
      expect(_decode(archive, archive.length), source);
      for (final piece in [1, 7, 34]) {
        expect(_decode(archive, piece), source, reason: 'piece $piece');
      }
    });

    test('archive of several blocks decodes back', () {
      // Small blocks, so a few hundred kilobytes spans several of them
      final source = _source(400000, 7);
      final archive = _encode(source, 1 << 16, blockSize100k: 1);
      for (final piece in [1, 101, 4096, archive.length]) {
        expect(_decode(archive, piece), source, reason: 'piece $piece');
      }
    });

    test('two concatenated archives decode as one', () {
      final source = _source(50000, 11);
      final one = _encode(source, 4096, blockSize100k: 1);
      final joined = Uint8List(one.length * 2)
        ..setRange(0, one.length, one)
        ..setRange(one.length, one.length * 2, one);
      final want = Uint8List(source.length * 2)
        ..setRange(0, source.length, source)
        ..setRange(source.length, source.length * 2, source);
      for (final piece in [7, 1024, joined.length]) {
        expect(_decode(joined, piece), want, reason: 'piece $piece');
      }
    });

    test('input that is not bzip2 throws ArchiveException', () {
      final bogus = Uint8List.fromList('not an archive at all'.codeUnits);
      expect(() => _decode(bogus, 4), throwsA(isA<ArchiveException>()));
    });

    test('empty input throws ArchiveException', () {
      expect(() => _decode(Uint8List(0), 1), throwsA(isA<ArchiveException>()));
    });

    test('block full of false markers is decoded once, not per marker', () {
      final bits = <int>[];
      void put(int value, int count) {
        for (var i = count - 1; i >= 0; i--) {
          bits.add((value >> i) & 1);
        }
      }

      for (final c in 'BZh9'.codeUnits) {
        put(c, 8);
      }
      put(0x314159265359, 48);
      put(0, 32);
      put(0, 1);
      put(0, 24);
      put(0x8000, 16);
      put(0x0006, 16);
      put(2, 3);
      put(18002, 15);
      put(0, 18002);
      for (var table = 0; table < 2; table++) {
        put(int.parse('0001001001111010100', radix: 2), 19);
      }
      for (var i = 0; i < 6000; i++) {
        put(0x314159265359, 48);
      }
      final archive = Uint8List((bits.length + 7) >> 3);
      for (var i = 0; i < bits.length; i++) {
        archive[i >> 3] |= bits[i] << (7 - (i & 7));
      }
      expect(
          BZip2Decoder()
              .decodeStream(InputMemoryStream(archive), OutputMemoryStream()),
          isFalse);
      final watch = Stopwatch()..start();
      for (final piece in [archive.length, 64]) {
        expect(() => _decode(archive, piece), throwsA(isA<ArchiveException>()),
            reason: 'piece $piece');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('block without end marker throws once input exceeds largest block',
        () {
      final archive = _encode(_source(100000, 5), 100000);
      final cut = Uint8List.sublistView(archive, 0, archive.length ~/ 2);
      final decoder = BZip2ChunkedDecoder(_Held());
      decoder.addSlice(cut, 0, cut.length, false);
      final zeros = Uint8List(1 << 16);
      var added = cut.length;
      expect(() {
        while (added < 16 << 20) {
          added += zeros.length;
          decoder.addSlice(zeros, 0, zeros.length, false);
        }
      }, throwsA(isA<ArchiveException>()));
      expect(added, lessThan(3 << 20));

      final input = InputMemoryStream(
          Uint8List(cut.length + (16 << 20))..setRange(0, cut.length, cut));
      final lazy = BZip2Decoder().decodeLazy(input);
      expect(lazy.toUint8List, throwsA(isA<ArchiveException>()));
      expect(input.position, lessThan(3 << 20));
    });

    // Marker search covered whole piece before block limit was checked, so
    // 64 MB in one add took 740 ms against 25 ms in 64 KB pieces
    test('block without end marker in one large add stops at largest block',
        () {
      final archive = _encode(_source(100000, 5), 100000);
      final cut = Uint8List.sublistView(archive, 0, archive.length ~/ 2);
      int failAfter(int zeros) {
        final bytes = Uint8List(cut.length + zeros)..setAll(0, cut);
        final watch = Stopwatch()..start();
        expect(
            () => BZip2ChunkedDecoder(_Held())
                .addSlice(bytes, 0, bytes.length, false),
            throwsA(isA<ArchiveException>()));
        return watch.elapsedMilliseconds;
      }

      failAfter(4 << 20);
      final small = failAfter(4 << 20);
      final large = failAfter(64 << 20);
      expect(large, lessThan(small * 4 + 150));
    });

    test('failed add keeps no copy of its piece', () {
      final archive = _encode(_source(100000, 5), 100000);
      final cut = Uint8List.sublistView(archive, 0, archive.length ~/ 2);
      final bytes = Uint8List(cut.length + (8 << 20))..setAll(0, cut);
      final decoder = BZip2ChunkedDecoder(_Held());
      expect(() => decoder.addSlice(bytes, 0, bytes.length, false),
          throwsA(isA<ArchiveException>()));
      expect(decoder.available, 0);
    });
  });

  group('bzip2 chunked encoder', () {
    test('output equals BZip2Encoder.encodeBytes output', () {
      for (final length in [0, 1, 999, 200000]) {
        final source = _source(length, length + 3);
        final want = BZip2Encoder().encodeBytes(source);
        for (final piece in [1, 13, 4096, 1 << 20]) {
          expect(_encode(source, piece < 1 ? 1 : piece), want,
              reason: 'length $length piece $piece');
        }
      }
    });

    test('input spanning several blocks decodes back', () {
      final source = _source(700000, 23);
      for (final blockSize100k in [1, 3, 9]) {
        final archive = _encode(source, 8192, blockSize100k: blockSize100k);
        expect(BZip2Decoder().decodeBytes(archive, verify: true), source,
            reason: 'blockSize100k $blockSize100k');
        expect(_decode(archive, 1024), source,
            reason: 'blockSize100k $blockSize100k');
      }
    });

    test('input ending exactly on block boundary decodes back', () {
      // The block fills at this many positions, and run coding means a block
      // can hold more raw bytes than that, so both sides of the edge matter
      const blockMax = 100000 - 19;
      for (final length in [
        blockMax - 1,
        blockMax,
        blockMax + 1,
        blockMax * 2,
        blockMax * 2 + 1,
      ]) {
        final source = _source(length, length);
        final want = BZip2Encoder().encodeBytes(source, blockSize100k: 1);
        for (final piece in [1, 4095, length]) {
          expect(_encode(source, piece, blockSize100k: 1), want,
              reason: 'length $length piece $piece');
        }
        expect(_decode(want, 1023), source, reason: 'length $length');
      }
    });

    test(
        'runs of 254 to 300000 equal bytes encode as BZip2Encoder and decode back',
        () {
      // 255 is where the run coding starts over, and a block then holds far
      // more raw bytes than it has positions
      for (final length in [254, 255, 256, 257, 300000]) {
        final source = Uint8List(length)..fillRange(0, length, 0x5a);
        expect(_encode(source, 997, blockSize100k: 1),
            BZip2Encoder().encodeBytes(source, blockSize100k: 1),
            reason: 'run $length');
        expect(_decode(_encode(source, 997, blockSize100k: 1), 64), source,
            reason: 'run $length');
      }
    });

    test('empty input writes valid empty archive', () {
      final held = _Held();
      BZip2ChunkedEncoder(held).close();
      expect(held.closed, isTrue);
      expect(held.bytes, BZip2Encoder().encodeBytes(Uint8List(0)));
      expect(_decode(held.bytes, 1), isEmpty);
    });

    test('block size outside 1..9 throws ArgumentError', () {
      expect(() => BZip2ChunkedEncoder(_Held(), blockSize100k: 0),
          throwsA(isA<ArgumentError>()));
      expect(() => BZip2ChunkedEncoder(_Held(), blockSize100k: 10),
          throwsA(isA<ArgumentError>()));
    });

    test('bzip2Codec with block size outside 1..9 throws ArgumentError',
        () async {
      expect(() => BZip2Codec(blockSize100k: 0).encode([1, 2, 3]),
          throwsA(isA<ArgumentError>()));
      await expectLater(
          () => Stream.value([1, 2, 3])
              .transform(BZip2Codec(blockSize100k: 10).encoder)
              .drain<void>(),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('bzip2 codec', () {
    test('convert output equals BZip2Encoder output and decodes back', () {
      final source = _source(120000, 31);
      final archive = bzip2Codec.encode(source);
      expect(archive, BZip2Encoder().encodeBytes(source));
      expect(bzip2Codec.decode(archive), source);
    });

    test('stream encodes and decodes back through bzip2Codec', () async {
      final source = _source(150000, 37);
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 9999) {
        final end = at + 9999 < source.length ? at + 9999 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final archive = await Stream.fromIterable(pieces)
          .transform(bzip2Codec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final back = await Stream.fromIterable([archive])
          .transform(bzip2Codec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(back, source);
    });

    // The input may stop sending without closing, as dart:io's gzip is
    // expected to cope with: what cannot be bzip2 fails at once, and a whole
    // archive is out before the input closes
    test('bytes that cannot start archive fail stream before input closes',
        () async {
      final source = StreamController<List<int>>();
      final failed = Completer<Object>();
      final subscription = source.stream
          .transform(bzip2Codec.decoder)
          .listen((_) {}, onError: failed.complete);
      source.add([0x42, 0x5a, 0x69]);
      expect(await failed.future.timeout(const Duration(seconds: 5)),
          isA<ArchiveException>());
      await subscription.cancel();
      await source.close();
    });

    test('complete archive is decoded before input stream closes', () async {
      final content = _source(3000, 41);
      final source = StreamController<List<int>>();
      final got = <int>[];
      final arrived = Completer<void>();
      final subscription =
          source.stream.transform(bzip2Codec.decoder).listen((piece) {
        got.addAll(piece);
        if (got.length >= content.length && !arrived.isCompleted) {
          arrived.complete();
        }
      });
      source.add(BZip2Encoder().encodeBytes(content));
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(got, content);
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
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

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// Sizes the encoder used to get wrong. Every archive here is read back with
// the checks on, which is what catches an index or a chunk that does not
// describe the block it belongs to

Uint8List _sample(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i * 7 + (i >> 8)) & 0xff;
  }
  return data;
}

void main() {
  group('xz encoder', () {
    // A block's unpadded length passes 127 at about a hundred bytes of input,
    // which is where the index needs a second byte, and it passes 16383 two
    // hundred bytes later. A chunk fills at 64 KiB
    const sizes = [
      0,
      1,
      6,
      100,
      104,
      110,
      1000,
      16383,
      16384,
      65535,
      65536,
      65537,
      200000,
    ];
    for (final size in sizes) {
      test('$size bytes decode back unchanged', () {
        final source = _sample(size);
        final archive = XZEncoder().encodeBytes(source);
        expect(
            XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }

    for (final check in XZCheck.values) {
      test('$check archive of 1000 bytes decodes back', () {
        final source = _sample(1000);
        final archive = XZEncoder().encodeBytes(source, check: check);
        expect(
            XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }

    for (final check in XZCheck.values) {
      test('$check archive is same in big-endian output', () {
        final source = _sample(1000);
        final expected = XZEncoder().encodeBytes(source, check: check);
        final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
        XZEncoder()
            .encodeStream(InputMemoryStream(source), output, check: check);
        expect(output.getBytes(), expected);
        expect(output.byteOrder, ByteOrder.bigEndian);
      });
    }

    test('archive written after other bytes is unchanged', () {
      final source = _sample(1001);
      final expected = XZEncoder().encodeBytes(source);
      final output = OutputMemoryStream()..writeBytes([1, 2, 3]);
      XZEncoder().encodeStream(InputMemoryStream(source), output);
      expect(Uint8List.sublistView(output.getBytes(), 3), expected);
    });

    test('encodeStream reads input chunk by chunk', () {
      final source = _sample(200000);
      for (final check in XZCheck.values) {
        final expected = XZEncoder().encodeBytes(source, check: check);
        for (final view in [true, false]) {
          final input = _ChunkReads([0, 0, ...source], view: view)..skip(2);
          final output = OutputMemoryStream();
          XZEncoder().encodeStream(input, output, check: check);
          expect(output.getBytes(), expected, reason: '$check, view $view');
          expect(input.position, 2, reason: '$check, view $view');
        }
      }
    });
  });

  group('xz chunked encoder', () {
    Uint8List encode(Uint8List source, int piece, {XZCheck? check}) {
      final held = _Held();
      final encoder = check == null
          ? XzChunkedEncoder(held)
          : XzChunkedEncoder(held, check: check);
      for (var at = 0; at < source.length; at += piece) {
        final end = at + piece < source.length ? at + piece : source.length;
        encoder.add(Uint8List.sublistView(source, at, end));
      }
      encoder.close();
      return held.bytes;
    }

    for (final size in [0, 6, 1000, 65535, 65536, 65537, 200000]) {
      test('$size bytes in pieces give same archive as whole input', () {
        final source = _sample(size);
        // The pieces the input arrives in must not reach the archive
        final whole = XZEncoder().encodeBytes(source);
        for (final piece in [1, 7, 4096, 65536, size + 1]) {
          expect(encode(source, piece), whole, reason: 'piece size $piece');
        }
      });
    }

    for (final check in [
      XZCheck.none,
      XZCheck.crc32,
      XZCheck.crc64,
      XZCheck.sha256
    ]) {
      test('$check archive decodes back', () {
        final source = _sample(5000);
        final archive = encode(source, 700, check: check);
        expect(
            XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }

    test('SHA-256 archive equals XZEncoder output', () {
      final source = _sample(200000);
      final whole = XZEncoder().encodeBytes(source, check: XZCheck.sha256);
      for (final piece in [1, 7, 4096, 65536, source.length + 1]) {
        expect(encode(source, piece, check: XZCheck.sha256), whole,
            reason: 'piece size $piece');
      }
      final held = _Held();
      const XzCodec(check: XZCheck.sha256).encoder.startChunkedConversion(held)
        ..add(source)
        ..close();
      expect(held.bytes, whole);
    });

    test('threaded stream decoder decodes this output', () async {
      // Without isolates, on the web, the same options fall back to one thread
      final source = _sample(300000);
      final decoded =
          await Stream<List<int>>.value(XZEncoder().encodeBytes(source))
              .transform(const XzCodec(
                      multithread:
                          XZMultithreadOptions<Object?>.converter(workers: 2))
                  .decoder)
              .fold<List<int>>(<int>[], (all, piece) => all..addAll(piece));
      expect(decoded, source);
    });

    test('any input size and piece size give archive that decodes back', () {
      final random = Random(20260911);
      for (var round = 0; round < 60; round++) {
        final size = random.nextInt(200000);
        final source = _sample(size);
        final held = _Held();
        final encoder = XzChunkedEncoder(held);
        var at = 0;
        while (at < size) {
          // Pieces of no particular size, the way a source hands them over
          final take = 1 + random.nextInt(70000);
          final end = at + take < size ? at + take : size;
          encoder.addSlice(source, at, end, false);
          at = end;
        }
        encoder.close();
        final archive = held.bytes;
        expect(
            XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source,
            reason: 'size $size');
        expect(archive, XZEncoder().encodeBytes(source), reason: 'size $size');
      }
    });

    test('Stream encodes and decodes back through xzCodec converters',
        () async {
      final source = _sample(300000);
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 8192) {
        final end = at + 8192 < source.length ? at + 8192 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final got = <int>[];
      await for (final piece in Stream<List<int>>.fromIterable(pieces)
          .transform(xzCodec.encoder)
          .transform(xzCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, source);
    });
  });
}

class _ChunkReads extends InputMemoryStream {
  _ChunkReads(super.bytes, {required this.view});

  final bool view;

  @override
  Uint8List toUint8List() {
    if (length > 1 << 16) {
      throw StateError('read $length bytes at once');
    }
    return super.toUint8List();
  }

  @override
  Uint8List? viewBytes(int count) => view ? super.viewBytes(count) : null;
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {}

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

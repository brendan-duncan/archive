@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

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
  final small = File('test/_data/bzip2/test.bz2').readAsBytesSync();

  group('bzip2 chunked decoder', () {
    test('archive in pieces of any size decodes as BZip2Decoder does', () {
      final want = BZip2Decoder().decodeBytes(small, verify: true);
      for (final piece in [1, 3, 64, 813, 1 << 16]) {
        expect(_decode(small, piece), want, reason: 'piece $piece');
      }
    });

    test('truncated archive throws ArchiveException', () {
      expect(
          () => _decode(Uint8List.sublistView(small, 0, small.length - 4), 8),
          throwsA(isA<ArchiveException>()));
    });

    test('wrong block CRC throws with verify, passes without it', () {
      final broken = Uint8List.fromList(small);
      // The stored block check sits right behind the 48 bit marker, which the
      // signature puts on a byte boundary for the first block
      broken[10] ^= 0xff;
      expect(() => _decode(broken, 16), throwsA(isA<ArchiveException>()));
      expect(() => _decode(broken, 16, verify: false), returnsNormally);
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

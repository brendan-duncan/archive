@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

class _ChunkOnlyInput extends InputMemoryStream {
  _ChunkOnlyInput(super.bytes, {this.maximumRead});

  final int? maximumRead;
  final buffers = Set<Uint8List>.identity();

  int calls = 0;

  @override
  int get length => throw StateError('eager length requested');

  @override
  InputStream readBytes(int count) =>
      throw StateError('eager readBytes($count) requested');

  @override
  int readInto(Uint8List into, int at, int count) {
    calls++;
    buffers.add(into);
    final limit = maximumRead;
    return super
        .readInto(into, at, limit != null && limit < count ? limit : count);
  }
}

Uint8List _payload(int length) {
  var state = 0x127bc921;
  return Uint8List.fromList(List<int>.generate(length, (_) {
    state = (state * 1664525 + 1013904223) & 0xffffffff;
    return state >> 16 & 255;
  }));
}

void main() {
  test('GZip native encoder consumes input in bounded chunks', () {
    final bytes = _payload(2 * 1024 * 1024);
    final source = _ChunkOnlyInput(bytes);
    final packed = OutputMemoryStream();
    GZipEncoder().encodeStream(source, packed, level: 1);

    expect(source.calls, greaterThan(10));
    expect(source.position, bytes.length);
    expect(GZipDecoder().decodeBytes(packed.getBytes(), verify: true), bytes);
  });

  test('ZLib native encoder consumes input in bounded chunks', () {
    final bytes = _payload(2 * 1024 * 1024);
    final source = _ChunkOnlyInput(bytes);
    final packed = OutputMemoryStream();
    ZLibEncoder().encodeStream(source, packed, level: 1);

    expect(source.calls, greaterThan(10));
    expect(source.position, bytes.length);
    expect(ZLibDecoder().decodeBytes(packed.getBytes(), verify: true), bytes);
  });

  test('small chunks and empty inputs remain valid compressed streams', () {
    for (final data in <List<int>>[
      [],
      [0],
      [1, 2, 3, 4, 5],
    ]) {
      final gz = OutputMemoryStream();
      GZipEncoder().encodeStream(_ChunkOnlyInput(data), gz);
      expect(GZipDecoder().decodeBytes(gz.getBytes(), verify: true), data);

      final z = OutputMemoryStream();
      ZLibEncoder().encodeStream(_ChunkOnlyInput(data), z);
      expect(ZLibDecoder().decodeBytes(z.getBytes(), verify: true), data);
    }
  });

  for (final gzip in [true, false]) {
    test('native ${gzip ? 'GZip' : 'ZLib'} keeps lazy input position at EOF',
        () {
      final bytes = _payload(65543);
      final source = GZipDecoder().decodeLazy(
          InputMemoryStream(GZipEncoder().encodeBytes(bytes)),
          verify: true);
      final output = OutputMemoryStream();
      if (gzip) {
        GZipEncoder().encodeStream(source, output);
      } else {
        ZLibEncoder().encodeStream(source, output);
      }
      expect(source.position, bytes.length);
      expect(source.isEOS, isTrue);
      expect(
          gzip
              ? GZipDecoder().decodeBytes(output.getBytes(), verify: true)
              : ZLibDecoder().decodeBytes(output.getBytes(), verify: true),
          bytes);
    });
  }

  test('native encoders reuse one buffer through short reads at all levels',
      () {
    final bytes = _payload(131079);
    for (final gzip in [true, false]) {
      for (final level in [0, 1, 6, 9]) {
        final source = _ChunkOnlyInput(bytes, maximumRead: 997)..skip(7);
        final output = OutputMemoryStream();
        if (gzip) {
          GZipEncoder().encodeStream(source, output, level: level);
        } else {
          ZLibEncoder().encodeStream(source, output, level: level);
        }
        expect(source.buffers, hasLength(1));
        expect(source.position, bytes.length);
        expect(
            gzip
                ? GZipDecoder().decodeBytes(output.getBytes(), verify: true)
                : ZLibDecoder().decodeBytes(output.getBytes(), verify: true),
            bytes.sublist(7));
      }
    }
  });
}

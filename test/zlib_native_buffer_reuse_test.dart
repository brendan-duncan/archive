@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

/// Refuses large eager reads so the decoder must use the bounded readInto
/// path. Small reads for checksum trailers remain available.
class _ReadIntoOnly extends InputMemoryStream {
  _ReadIntoOnly(super.bytes, {this.maxRead = 1 << 30});

  final int maxRead;
  int bulkReads = 0;
  Uint8List? scratch;

  // No views, so it is read as a file is
  @override
  Uint8List? viewBytes(int count) => null;

  @override
  InputStream readBytes(int count) {
    if (count > 4100) {
      throw StateError('unexpected allocating readBytes($count)');
    }
    return super.readBytes(count);
  }

  @override
  int readInto(Uint8List into, int at, int count) {
    bulkReads++;
    scratch ??= into;
    expect(identical(into, scratch), isTrue);
    return super.readInto(into, at, count > maxRead ? maxRead : count);
  }
}

Uint8List _incompressible(int size) {
  var state = 0x1d3a5c7b;
  return Uint8List.fromList(List<int>.generate(size, (_) {
    state = (state * 1664525 + 1013904223) & 0xffffffff;
    return (state >> 16) & 255;
  }));
}

void main() {
  for (final raw in [false, true]) {
    for (final verify in [false, true]) {
      test('short reads at nonzero position: raw=$raw verify=$verify', () {
        final source = _incompressible(20000);
        final wrapped = ZLibEncoder().encodeBytes(source);
        final compressed =
            raw ? wrapped.sublist(2, wrapped.length - 4) : wrapped;
        final input = _ReadIntoOnly(
            Uint8List.fromList([1, 2, 3, ...compressed]),
            maxRead: 137)
          ..skip(3);
        final output = OutputMemoryStream();
        expect(
            ZLibDecoder().decodeStream(input, output,
                raw: raw, verify: verify, throwOnError: true),
            isTrue);
        expect(output.getBytes(), source);
        expect(input.isEOS, isTrue);
        expect(input.bulkReads, greaterThan(100));
      });
    }
  }

  test('native ZLib stream decoder reuses readInto across many chunks', () {
    final source = _incompressible(2 * 1024 * 1024);
    final compressed = ZLibEncoder().encodeBytes(source);
    final input = _ReadIntoOnly(compressed);
    final output = OutputMemoryStream();

    expect(
        ZLibDecoder().decodeStream(input, output, throwOnError: true), isTrue);
    expect(output.getBytes(), source);
    expect(input.bulkReads, greaterThan(1));
  });

  test('native ZLib stream decoder handles the raw deflate mode', () {
    final source = _incompressible(2 * 1024 * 1024);
    final compressed = ZLibEncoder().encodeBytes(source);
    // Strip zlib header and 4-byte Adler checksum to get raw deflate data.
    final input = _ReadIntoOnly(
      Uint8List.sublistView(compressed, 2, compressed.length - 4),
    );
    final output = OutputMemoryStream();
    expect(
        ZLibDecoder()
            .decodeStream(input, output, raw: true, throwOnError: true),
        isTrue);
    expect(output.getBytes(), source);
    expect(input.bulkReads, greaterThan(1));
  });
}

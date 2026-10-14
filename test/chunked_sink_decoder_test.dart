import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/chunked_sink.dart';
import 'package:test/test.dart';

// A decodeLazy stream holds what one decodeChunk call writes, so a call that
// decodes a whole archive lets a small bomb fill memory. Each format stops
// after one of its units.
({int total, int largest}) drain(ChunkDecoder decoder) {
  var total = 0;
  var largest = 0;
  while (true) {
    final output = OutputMemoryStream();
    final more = decoder.decodeChunk(output);
    total += output.length;
    if (output.length > largest) {
      largest = output.length;
    }
    if (!more) {
      return (total: total, largest: largest);
    }
  }
}

void main() {
  // A frame's last window is held to its end, as decodeStream holds it, so a
  // chunk is at most a window: 2 MB for this frame
  test('zstd decodes at most one window per chunk', () {
    final data = Uint8List(16 << 20);
    final z = ZstdEncoder().encodeBytes(data);
    final result = drain(ChunkedSinkDecoder(
        InputMemoryStream(z), (output) => ZstdChunkedDecoder(output)));
    expect(result.total, data.length);
    expect(result.largest, lessThanOrEqualTo(4 << 20));
  });

  test('bzip2 decodes at most one block per chunk', () {
    // No runs, so a block holds 900000 bytes, and several blocks fit in the
    // 64 KB of input one call reads
    final data = Uint8List.fromList(List.generate(4 << 20, (i) => i % 251));
    final bz = BZip2Encoder().encodeBytes(data);
    expect(bz.length, lessThan(1 << 16));
    final result = drain(ChunkedSinkDecoder(
        InputMemoryStream(bz), (output) => BZip2ChunkedDecoder(output)));
    expect(result.total, data.length);
    expect(result.largest, lessThanOrEqualTo(900000));
  });
}

import 'dart:typed_data';

import 'zstd_huffman.dart';

/// Decodes [count] literals from one stream into `dst[dstStart...]`
void decodeHuffmanStream(ZstdHuffmanTable table, Uint8List src, int start,
    int length, Uint8List dst, int dstStart, int count) {
  decodeHuffmanStreamSlow(table, src, start, length, dst, dstStart, count);
}

/// The four streams are independent, so on a target with no wide bit container
/// to keep fed there is nothing to gain from interleaving them
void decodeHuffman4Streams(
    ZstdHuffmanTable table,
    Uint8List src,
    Uint32List starts,
    Uint32List lengths,
    Uint8List dst,
    int dstStart,
    int total,
    int segment) {
  final tail = total - 3 * segment;
  if (tail < 0 || tail > segment) {
    throw ZstdHuffmanException('Stream split does not add up');
  }
  for (var s = 0; s < 4; s++) {
    decodeHuffmanStreamSlow(table, src, starts[s], lengths[s], dst,
        dstStart + s * segment, s == 3 ? tail : segment);
  }
}

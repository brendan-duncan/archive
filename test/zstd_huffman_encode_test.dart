import 'dart:math';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_huffman.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_encoder.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_loop.dart';
import 'package:test/test.dart';

/// Builds a tree over [source], writes it with its streams, and reads both back
/// with the decoder's own code
void _roundTrip(Uint8List source) {
  final counts = Uint32List(256);
  for (final byte in source) {
    counts[byte]++;
  }
  final encoder = ZstdHuffmanEncoder();
  expect(encoder.build(counts, source.length), isTrue);
  for (var s = 0; s < 256; s++) {
    expect(encoder.widths[s], lessThanOrEqualTo(11), reason: 'symbol $s');
    if (counts[s] == 0) {
      expect(encoder.widths[s], 0, reason: 'unused symbol $s');
    } else {
      expect(encoder.widths[s], greaterThan(0), reason: 'used symbol $s');
    }
  }

  final out = Uint8List(source.length * 2 + 1024);
  final tableSize = encoder.writeTable(out, 0);
  expect(tableSize, greaterThan(0));
  final streamsSize =
      encoder.encodeLiterals(out, tableSize, source, 0, source.length);
  expect(streamsSize, greaterThan(0));

  final table = ZstdHuffmanTable();
  final read = readHuffmanTable(out, 0, tableSize, table, ZstdHuffmanScratch());
  expect(read, tableSize);
  expect(table.tableLog, encoder.tableLog);

  final decoded = Uint8List(source.length);
  if (source.length < zstdFourStreamsFrom) {
    decodeHuffmanStream(
        table, out, tableSize, streamsSize, decoded, 0, source.length);
  } else {
    final starts = Uint32List(4);
    final lengths = Uint32List(4);
    final l0 = out[tableSize] | (out[tableSize + 1] << 8);
    final l1 = out[tableSize + 2] | (out[tableSize + 3] << 8);
    final l2 = out[tableSize + 4] | (out[tableSize + 5] << 8);
    starts[0] = tableSize + 6;
    starts[1] = starts[0] + l0;
    starts[2] = starts[1] + l1;
    starts[3] = starts[2] + l2;
    lengths[0] = l0;
    lengths[1] = l1;
    lengths[2] = l2;
    lengths[3] = streamsSize - 6 - l0 - l1 - l2;
    decodeHuffman4Streams(table, out, starts, lengths, decoded, 0,
        source.length, (source.length + 3) >> 2);
  }
  expect(decoded, source);
}

Uint8List _fromWeights(List<int> weights, int length, Random random) {
  var total = 0;
  for (final w in weights) {
    total += w;
  }
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    var pick = random.nextInt(total);
    var s = 0;
    while (pick >= weights[s]) {
      pick -= weights[s];
      s++;
    }
    out[i] = s;
  }
  return out;
}

void main() {
  group('zstd Huffman encoder', () {
    test('short run of 2 symbols decodes back', () {
      _roundTrip(
          Uint8List.fromList(List.generate(100, (i) => i % 7 == 0 ? 65 : 66)));
    });

    test('single stream of text decodes back', () {
      const text = 'the quick brown fox jumps over the lazy dog, again and '
          'again, until the letters settle into a shape worth coding';
      _roundTrip(Uint8List.fromList(text.codeUnits));
    });

    test('4 streams decode back', () {
      final random = Random(11);
      _roundTrip(_fromWeights(
          List.generate(60, (i) => 1 + (60 - i) * (60 - i)), 20000, random));
    });

    test('symbols above 128 decode back', () {
      final random = Random(12);
      final weights = List.generate(256, (i) => i < 200 ? 1 : 400);
      _roundTrip(_fromWeights(weights, 30000, random));
    });

    test('tree deeper than 11 bits is limited to 11', () {
      // Fibonacci counts make the natural tree one bit deeper per symbol, so
      // thirty of them ask for a code far past the eleven the format allows
      final counts = Uint32List(256);
      var a = 1;
      var b = 1;
      for (var s = 0; s < 30; s++) {
        counts[s] = a;
        final next = a + b;
        a = b;
        b = next;
      }
      final encoder = ZstdHuffmanEncoder();
      var total = 0;
      for (var s = 0; s < 30; s++) {
        total += counts[s];
      }
      expect(encoder.build(counts, total), isTrue);
      var widest = 0;
      for (var s = 0; s < 30; s++) {
        if (encoder.widths[s] > widest) {
          widest = encoder.widths[s];
        }
      }
      expect(widest, lessThanOrEqualTo(11));
      expect(widest, greaterThan(8));

      final random = Random(13);
      _roundTrip(
          _fromWeights(List.generate(30, (s) => counts[s]), 40000, random));
    });

    test('random distributions decode back', () {
      final random = Random(20260909);
      for (var round = 0; round < 60; round++) {
        final used = 2 + random.nextInt(254);
        final weights = List.generate(256, (i) => 0);
        for (var i = 0; i < used; i++) {
          weights[random.nextInt(256)] = 1 + random.nextInt(1000);
        }
        var live = 0;
        for (final w in weights) {
          if (w > 0) {
            live++;
          }
        }
        if (live < 2) {
          continue;
        }
        final length = 64 + random.nextInt(4000);
        _roundTrip(_fromWeights(weights, length, random));
      }
    });
  });
}

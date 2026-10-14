import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_constants.dart';
import 'package:archive/src/codecs/zstd/zstd_fse.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_encoder.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_loop.dart';
import 'package:archive/src/codecs/zstd/zstd_literals.dart';
import 'package:archive/src/codecs/zstd/zstd_literals_encoder.dart';
import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:test/test.dart';

/// A tree description in the direct form: a header of `127 + count` and the
/// weights packed a nibble each, high nibble first
Uint8List _direct(List<int> weights) {
  final bytes = Uint8List(1 + ((weights.length + 1) >> 1));
  bytes[0] = 127 + weights.length;
  for (var i = 0; i < weights.length; i++) {
    if (i.isEven) {
      bytes[1 + (i >> 1)] = weights[i] << 4;
    } else {
      bytes[1 + (i >> 1)] |= weights[i];
    }
  }
  return bytes;
}

/// Literals whose byte distribution is uneven enough to be worth a tree, with
/// [spread] distinct bytes
Uint8List _literals(int length, int spread) {
  final out = Uint8List(length);
  var seed = 12345;
  for (var at = 0; at < length; at++) {
    seed = (seed * 1103515245 + 12345) & 0x3fffffff;
    // A skewed pick, so a few bytes carry most of the weight
    final draw = (seed >> 8) % 100;
    out[at] = draw < 60 ? 0x41 : 0x41 + (seed % spread);
  }
  return out;
}

void main() {
  group('zstd fixed-width stream end', () {
    for (final slow in [false, true]) {
      for (final symbols in [8, 32, 64]) {
        for (final count in [symbols - 1, symbols, symbols + 1]) {
          test(
              'slow $slow accepts exactly $symbols 1-bit symbols, count $count',
              () {
            final table = ZstdHuffmanTable();
            final tree = _direct([1]);
            readHuffmanTable(tree, 0, tree.length, table, ZstdHuffmanScratch());
            final encoded = Uint8List((symbols >> 3) + 1)..last = 1;
            final output = Uint8List(symbols + 8)
              ..fillRange(0, symbols + 8, 0xa5);
            void decode() {
              if (slow) {
                decodeHuffmanStreamSlow(
                    table, encoded, 0, encoded.length, output, 3, count);
              } else {
                decodeHuffmanStream(
                    table, encoded, 0, encoded.length, output, 3, count);
              }
            }

            if (count == symbols) {
              decode();
              expect(output.sublist(0, 3), everyElement(0xa5));
              expect(output.sublist(3, symbols + 3), everyElement(0));
              expect(output.sublist(symbols + 3), everyElement(0xa5));
            } else {
              expect(decode, throwsA(isA<ZstdHuffmanException>()));
            }
          });
        }
      }
    }
  });

  group('zstd single-stream boundaries', () {
    for (final slow in [false, true]) {
      for (final count in [
        1,
        2,
        3,
        4,
        7,
        8,
        13,
        14,
        15,
        16,
        17,
        31,
        32,
        33,
        34,
        65,
        66,
        67
      ]) {
        test('slow $slow count $count reads exactly its stream', () {
          final fixture = _SingleStreamFixture(count);
          final decoded = fixture.decode(slow: slow);
          expect(Uint8List.sublistView(decoded, 7, 7 + count), fixture.source);
          expect(decoded.sublist(0, 7), everyElement(0xa5));
          expect(decoded.sublist(7 + count), everyElement(0xa5));
        });
      }
      for (final count in [2, 3, 14, 15, 16, 17, 66, 67]) {
        for (final delta in [-1, 1]) {
          test('slow $slow count $count rejects symbol count off by $delta',
              () {
            final fixture = _SingleStreamFixture(count);
            expect(() => fixture.decode(slow: slow, count: count + delta),
                throwsA(isA<ZstdHuffmanException>()));
          });
        }
      }
    }
  });

  group('zstd four-stream boundaries', () {
    for (final wide in [false, true]) {
      for (final segment in [65, 66, 67, 68, 129, 130, 131, 132]) {
        for (var missing = 0; missing < 4; missing++) {
          test('wide $wide segment $segment missing $missing throws', () {
            final fixture = _FourStreamFixture(segment, missing, wide: wide);
            final decoded = fixture.decode();
            expect(Uint8List.sublistView(decoded, 7, 7 + fixture.source.length),
                fixture.source);
            expect(decoded.sublist(0, 7), everyElement(0xa5));
            expect(
                decoded.sublist(7 + fixture.source.length), everyElement(0xa5));
          });
        }
      }
      for (var stream = 0; stream < 4; stream++) {
        test('wide $wide stream $stream without end marker throws', () {
          final fixture = _FourStreamFixture(66, 0, wide: wide);
          final broken = Uint8List.fromList(fixture.encoded);
          broken[fixture.starts[stream] + fixture.lengths[stream] - 1] = 0;
          expect(() => fixture.decode(bytes: broken),
              throwsA(isA<ZstdHuffmanException>()));
        });
      }
    }
    for (final segment in [66, 67]) {
      for (var stream = 0; stream < 4; stream++) {
        test('segment $segment stream $stream with truncated prefix throws',
            () {
          final fixture = _FourStreamFixture(segment, 0, wide: false);
          final starts = Uint32List.fromList(fixture.starts);
          final lengths = Uint32List.fromList(fixture.lengths);
          starts[stream]++;
          lengths[stream]--;
          expect(() => fixture.decode(starts: starts, lengths: lengths),
              throwsA(isA<ZstdHuffmanException>()));
        });
      }
    }
    test('coded symbols beyond declared output throw', () {
      final fixture = _FourStreamFixture(66, 0, wide: false);
      expect(() => fixture.decode(total: 260, segment: 65),
          throwsA(isA<ZstdHuffmanException>()));
    });
  });

  group('zstd huffman table', () {
    final table = ZstdHuffmanTable();
    final scratch = ZstdHuffmanScratch();

    void rejects(Uint8List bytes, String reason) {
      expect(() => readHuffmanTable(bytes, 0, bytes.length, table, scratch),
          throwsA(isA<ZstdHuffmanException>()),
          reason: reason);
    }

    test('description of 3 weights builds table', () {
      final bytes = _direct([2, 1, 1]);
      final read = readHuffmanTable(bytes, 0, bytes.length, table, scratch);
      expect(read, bytes.length);
      // The weight left over is the one the last symbol takes
      expect(table.symbolCount, 4);
      expect(table.tableLog, 3);
      var filled = 0;
      for (var at = 0; at < 1 << table.tableLog; at++) {
        if (table.rows[at] != 0) filled++;
      }
      expect(filled, greaterThan(0));
    });

    test('empty description throws', () {
      rejects(Uint8List(0), 'nothing to read');
    });

    test('truncated direct weights throw', () {
      final bytes = _direct(List.filled(17, 1));
      rejects(Uint8List.sublistView(bytes, 0, 4), 'nibbles are missing');
    });

    test('truncated compressed weights throw', () {
      rejects(
          Uint8List.fromList([5, 0, 0]), 'the description claims five bytes');
    });

    test('weight past longest code throws', () {
      rejects(_direct([15, 1]), 'fifteen is above the twelve allowed');
    });

    test('all-zero weights throw', () {
      rejects(_direct([0, 0]), 'no symbol carries anything');
    });

    test('weights without weight-1 symbols throw', () {
      rejects(_direct([2]), 'the completed tree has no weight-one symbols');
    });

    test('weight above maximum code length throws', () {
      rejects(_direct([12, 12]), 'twelve is above the eleven allowed');
    });

    // Two of the heaviest weight the format does allow still add up past the
    // widest table, which is caught after the weights themselves pass
    test('weights overflowing table log throw', () {
      rejects(_direct([11, 11]), 'the total needs a table log of twelve');
    });

    test('weights that leave gap throw', () {
      rejects(_direct([1, 1, 1, 1, 1]), 'what is left is not a power of two');
    });

    test('weight count of 1 symbol throws', () {
      rejects(_direct([]), 'a description covers at least one weight');
    });
  });

  // The encoder writes a description, the decoder reads it back: whichever
  // form the encoder picked for the weights is the one under test
  group('zstd huffman round trip', () {
    for (final spread in [3, 12, 60, 200]) {
      test('tree over $spread symbols decodes back', () {
        final source = _literals(20000, spread);
        final counts = Uint32List(zstdHuffmanSymbolCount);
        for (final b in source) {
          counts[b]++;
        }
        final encoder = ZstdHuffmanEncoder();
        expect(encoder.build(counts, source.length), isTrue);
        final written = Uint8List(1024);
        final size = encoder.writeTable(written, 0);
        expect(size, greaterThan(0));

        final table = ZstdHuffmanTable();
        final scratch = ZstdHuffmanScratch();
        final read = readHuffmanTable(written, 0, size, table, scratch);
        expect(read, size);
        expect(table.tableLog, encoder.tableLog);
      });
    }

    test('description truncated anywhere throws or decodes shorter', () {
      final source = _literals(20000, 60);
      final counts = Uint32List(zstdHuffmanSymbolCount);
      for (final b in source) {
        counts[b]++;
      }
      final encoder = ZstdHuffmanEncoder()..build(counts, source.length);
      final written = Uint8List(1024);
      final size = encoder.writeTable(written, 0);
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      for (var cut = 0; cut < size; cut++) {
        try {
          final read = readHuffmanTable(written, 0, cut, table, scratch);
          expect(read, lessThanOrEqualTo(cut), reason: 'cut to $cut');
        } on ZstdHuffmanException {
          continue;
        } on ZstdFseException {
          continue;
        } catch (error) {
          fail('cut to $cut threw $error');
        }
      }
    });

    test('description with changed byte throws or decodes', () {
      final source = _literals(20000, 60);
      final counts = Uint32List(zstdHuffmanSymbolCount);
      for (final b in source) {
        counts[b]++;
      }
      final encoder = ZstdHuffmanEncoder()..build(counts, source.length);
      final written = Uint8List(1024);
      final size = encoder.writeTable(written, 0);
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      for (var at = 0; at < size; at++) {
        for (var bit = 0; bit < 8; bit++) {
          final bytes =
              Uint8List.fromList(Uint8List.sublistView(written, 0, size));
          bytes[at] ^= 1 << bit;
          try {
            readHuffmanTable(bytes, 0, size, table, scratch);
          } on ZstdHuffmanException {
            continue;
          } on ZstdFseException {
            continue;
          } catch (error) {
            fail('bit $bit of byte $at threw $error');
          }
        }
      }
    });
  });

  // A literals section carries the tree and the streams together, which is the
  // only way the four stream layout and the short stream fallback are reached
  group('zstd literals round trip', () {
    for (final size in [8, 40, 64, 200, 1000, 5000, 60000, 131072]) {
      for (final spread in [4, 90]) {
        test('$size literals over $spread symbols decode back', () {
          final source = _literals(size, spread);
          final encoder = ZstdLiteralsEncoder()..minSize = 6;
          final out = Uint8List(size + (size >> 1) + 1024);
          final coded = encoder.encode(out, 0, source, 0, source.length);
          expect(coded, greaterThan(0));

          final into = Uint8List(size + 32);
          final literals = ZstdLiterals();
          final read = literals.decode(out, 0, coded, 1 << 17, into, 0);
          expect(read, coded);
          expect(literals.length, size);
          expect(
              getCrc32(Uint8List.sublistView(into, 0, size)), getCrc32(source));
        });
      }
    }

    // One stream is written whenever the literals are few, and the header is
    // three bytes: ten bits of regenerated size, ten of compressed
    test('slow loop decodes same as wide loop', () {
      for (final size in [12, 40, 200, 900]) {
        final source = _literals(size, 30);
        final encoder = ZstdLiteralsEncoder()..minSize = 6;
        final out = Uint8List(size + 1024);
        final coded = encoder.encode(out, 0, source, 0, source.length);
        if (out[0] & 3 != zstdLiteralsCompressed || (out[0] >> 2) & 3 != 0) {
          continue;
        }
        final regenerated = (out[0] >> 4) | ((out[1] & 0x3f) << 4);
        final compressed = (out[1] >> 6) | (out[2] << 2);
        expect(regenerated, size);
        expect(compressed, coded - 3);

        final table = ZstdHuffmanTable();
        final scratch = ZstdHuffmanScratch();
        final tree = readHuffmanTable(out, 3, 3 + compressed, table, scratch);
        final start = 3 + tree;
        final length = compressed - tree;

        final wide = Uint8List(size);
        decodeHuffmanStream(table, out, start, length, wide, 0, size);
        final slow = Uint8List(size);
        decodeHuffmanStreamSlow(table, out, start, length, slow, 0, size);
        expect(slow, wide, reason: '$size literals');
        expect(getCrc32(slow), getCrc32(source), reason: '$size literals');
      }
    });

    test('slow loop with nothing to decode writes nothing', () {
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      final bytes = _direct([2, 1, 1]);
      readHuffmanTable(bytes, 0, bytes.length, table, scratch);
      final dst = Uint8List(4);
      decodeHuffmanStreamSlow(table, Uint8List.fromList([1]), 0, 1, dst, 0, 0);
      expect(dst, Uint8List(4));
    });

    test('literals section truncated anywhere throws', () {
      final source = _literals(5000, 60);
      final encoder = ZstdLiteralsEncoder()..minSize = 6;
      final out = Uint8List(8192);
      final coded = encoder.encode(out, 0, source, 0, source.length);
      final into = Uint8List(8192);
      for (var cut = 1; cut < coded; cut++) {
        final literals = ZstdLiterals();
        expect(() => literals.decode(out, 0, cut, 1 << 17, into, 0),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });
  });
}

class _FourStreamFixture {
  final int segment;
  final Uint8List source;
  final Uint8List encoded;
  final table = ZstdHuffmanTable();
  final starts = Uint32List(4);
  final lengths = Uint32List(4);

  _FourStreamFixture(this.segment, int missing, {required bool wide})
      : source = Uint8List(segment * 4 - missing),
        encoded = Uint8List(segment * 8 + 1024) {
    final weights = wide
        ? Uint8List.fromList([11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 1])
        : (Uint8List(16)..fillRange(0, 16, 1));
    for (var i = 0; i < source.length; i++) {
      source[i] = (i * 13 + (i >> 4)) % weights.length;
    }
    final encoder = ZstdHuffmanEncoder()..loadWeights(weights, wide ? 11 : 4);
    final treeSize = encoder.writeTable(encoded, 0);
    final coded =
        encoder.encodeLiterals(encoded, treeSize, source, 0, source.length);
    if (treeSize <= 0 || coded <= 0) {
      throw StateError('Fixture encoding failed');
    }
    readHuffmanTable(encoded, 0, treeSize, table, ZstdHuffmanScratch());
    var at = treeSize + 6;
    for (var stream = 0; stream < 4; stream++) {
      final header = treeSize + stream * 2;
      final length = stream < 3
          ? encoded[header] | (encoded[header + 1] << 8)
          : treeSize + coded - at;
      if (length < 8) throw StateError('Fixture missed the wide decoding path');
      starts[stream] = at;
      lengths[stream] = length;
      at += length;
    }
  }

  Uint8List decode(
      {Uint8List? bytes,
      Uint32List? starts,
      Uint32List? lengths,
      int? total,
      int? segment}) {
    final output = Uint8List(source.length + 14)
      ..fillRange(0, source.length + 14, 0xa5);
    decodeHuffman4Streams(
        table,
        bytes ?? encoded,
        starts ?? this.starts,
        lengths ?? this.lengths,
        output,
        7,
        total ?? source.length,
        segment ?? this.segment);
    return output;
  }
}

class _SingleStreamFixture {
  final Uint8List source;
  final Uint8List encoded;
  final table = ZstdHuffmanTable();
  late final int start;
  late final int length;

  _SingleStreamFixture(int count)
      : source = Uint8List(count),
        encoded = Uint8List(count * 2 + 1024) {
    for (var i = 0; i < count; i++) {
      source[i] = i & 15;
    }
    final encoder = ZstdHuffmanEncoder()
      ..loadWeights(Uint8List(16)..fillRange(0, 16, 1), 4)
      ..oneStream = true;
    start = encoder.writeTable(encoded, 0);
    length = encoder.encodeLiterals(encoded, start, source, 0, count);
    if (start <= 0 || length <= 0) throw StateError('Fixture encoding failed');
    readHuffmanTable(encoded, 0, start, table, ZstdHuffmanScratch());
  }

  Uint8List decode({required bool slow, int? count}) {
    final output = Uint8List(source.length + 16)
      ..fillRange(0, source.length + 16, 0xa5);
    if (slow) {
      decodeHuffmanStreamSlow(
          table, encoded, start, length, output, 7, count ?? source.length);
    } else {
      decodeHuffmanStream(
          table, encoded, start, length, output, 7, count ?? source.length);
    }
    return output;
  }
}

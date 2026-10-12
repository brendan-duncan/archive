@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:test/test.dart';

// Vectors written by zstd 1.5.7 against the two dictionaries stored beside
// them, one trained and one a plain slice of the sample data. As elsewhere only
// the compressed side is kept, with the length and CRC-32 of what it must
// decode to.
const _vectors = <List<Object>>[
  ['dv-empty-trained-l1.zst', 'trained', 0, 0],
  ['dv-empty-trained-l19.zst', 'trained', 0, 0],
  ['dv-empty-raw-l1.zst', 'raw', 0, 0],
  ['dv-empty-raw-l19.zst', 'raw', 0, 0],
  ['dv-tiny-trained-l1.zst', 'trained', 36, 2970607104],
  ['dv-tiny-trained-l19.zst', 'trained', 36, 2970607104],
  ['dv-tiny-raw-l1.zst', 'raw', 36, 2970607104],
  ['dv-tiny-raw-l19.zst', 'raw', 36, 2970607104],
  ['dv-small-trained-l1.zst', 'trained', 718, 943341646],
  ['dv-small-trained-l19.zst', 'trained', 718, 943341646],
  ['dv-small-raw-l1.zst', 'raw', 718, 943341646],
  ['dv-small-raw-l19.zst', 'raw', 718, 943341646],
  ['dv-large-trained-l19.zst', 'trained', 191930, 2898046530],
  ['dv-large-raw-l19.zst', 'raw', 191930, 2898046530],
  ['dv-multi-trained.zst', 'trained', 1472, 1575472477],
];

void main() {
  final directory = Directory('test/_data/zstd');

  group('zstd dictionaries', () {
    final dictionaries = {
      'trained': ZstdDictionary(
          File('${directory.path}/dict-trained.dict').readAsBytesSync()),
      'raw': ZstdDictionary(
          File('${directory.path}/dict-raw.dict').readAsBytesSync()),
    };

    test('trained dictionary has id and entropy tables', () {
      final trained = dictionaries['trained']!;
      expect(trained.hasEntropy, isTrue);
      expect(trained.id, isNot(0));
      expect(trained.repeatOffsets, hasLength(3));
    });

    test('other bytes are used as raw content dictionary', () {
      final raw = dictionaries['raw']!;
      expect(raw.hasEntropy, isFalse);
      expect(raw.id, 0);
      expect(raw.content, hasLength(3000));
      expect(ZstdDictionary(Uint8List(0)).content, isEmpty);
    });

    for (final vector in _vectors) {
      final name = vector[0] as String;
      final dictionary = dictionaries[vector[1] as String]!;
      final length = vector[2] as int;
      final crc = vector[3] as int;
      final bytes = File('${directory.path}/$name').readAsBytesSync();

      test('$name decodes in one piece', () {
        final decoded = ZstdDecoder.withDictionary(dictionary)
            .decodeBytes(bytes, verify: true, throwOnError: true);
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });

      test('$name decodes through stream', () {
        final output = OutputMemoryStream();
        final ok = ZstdDecoder.withDictionary(dictionary).decodeStream(
            InputMemoryStream(bytes), output,
            verify: true, throwOnError: true);
        expect(ok, isTrue);
        final decoded = output.getBytes();
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });
    }

    test('frame with dictionary id throws without dictionary', () {
      final bytes =
          File('${directory.path}/dv-small-trained-l19.zst').readAsBytesSync();
      expect(() => ZstdDecoder().decodeBytes(bytes, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('frame with dictionary id throws with wrong dictionary', () {
      final bytes =
          File('${directory.path}/dv-small-trained-l19.zst').readAsBytesSync();
      expect(
          () => ZstdDecoder.withDictionary(dictionaries['raw'])
              .decodeBytes(bytes, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('dictionary given for frame without id is still applied', () {
      final bytes =
          File('${directory.path}/dv-small-raw-l19.zst').readAsBytesSync();
      expect(ZstdDecoder().decodeBytes(bytes), isNot(hasLength(718)));
      final decoded = ZstdDecoder.withDictionary(dictionaries['raw'])
          .decodeBytes(bytes, verify: true, throwOnError: true);
      expect(getCrc32(decoded), 943341646);
    });

    test('dictionary truncated inside entropy tables throws', () {
      final full =
          File('${directory.path}/dict-trained.dict').readAsBytesSync();
      for (final cut in [9, 20, 64, 100]) {
        expect(() => ZstdDictionary(Uint8List.sublistView(full, 0, cut)),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });

    test('dictionary truncated inside entropy tables throws ArchiveException',
        () {
      final full =
          File('${directory.path}/dict-trained.dict').readAsBytesSync();
      for (final cut in [9, 20, 64, 100]) {
        expect(() => ZstdDictionary(Uint8List.sublistView(full, 0, cut)),
            throwsA(isA<ArchiveException>()),
            reason: 'cut to $cut bytes');
      }
    });

    test('dictionary truncated anywhere throws ArchiveException', () {
      final full =
          File('${directory.path}/dict-trained.dict').readAsBytesSync();
      for (var cut = 9; cut < full.length; cut++) {
        try {
          ZstdDictionary(Uint8List.sublistView(full, 0, cut));
        } catch (error) {
          expect(error, isA<FormatException>(), reason: 'cut to $cut bytes');
        }
      }
    });

    test('dictionary with too many Huffman weights throws ArchiveException',
        () {
      final damaged = Uint8List.fromList(
          File('${directory.path}/dict-trained.dict').readAsBytesSync());
      damaged[8] = 37;
      expect(() => ZstdDictionary(damaged), throwsA(isA<ArchiveException>()));
    });
  });
}

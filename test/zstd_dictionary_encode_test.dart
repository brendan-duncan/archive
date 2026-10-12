@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd/zstd_level_params.dart';
import 'package:archive/src/codecs/zstd/zstd_sequences_encoder.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:test/test.dart';

Uint8List _literalBlock() {
  final bytes = Uint8List(131072);
  final digits = Uint8List(4);
  var written = 0;
  void fill(int at, int period) {
    if (written == 131063) return;
    if (at > 3) {
      if (3 % period == 0) {
        for (var i = 1; i <= period && written < 131063; i++) {
          bytes[written++] = digits[i] + 128;
        }
      }
      return;
    }
    digits[at] = digits[at - period];
    fill(at + 1, period);
    for (var value = digits[at - period] + 1; value < 64; value++) {
      digits[at] = value;
      fill(at + 1, at);
    }
  }

  fill(1, 1);
  bytes.setRange(131067, 131072, bytes);
  return bytes;
}

// The decoder side of dictionaries is checked against libzstd's own frames in
// zstd_dictionary_test.dart, so a frame this encoder writes that reads back
// through it has been through the reference on the way
void main() {
  final directory = Directory('test/_data/zstd');
  final trainedBytes =
      File('${directory.path}/dict-trained.dict').readAsBytesSync();
  final rawBytes = File('${directory.path}/dict-raw.dict').readAsBytesSync();
  final trained = ZstdDictionary(trainedBytes);
  final raw = ZstdDictionary(rawBytes);

  final samples = <String, Uint8List>{
    'empty': Uint8List(0),
    'tiny': Uint8List.fromList('hello dictionary world'.codeUnits),
    'dictionary content': Uint8List.sublistView(raw.content),
    'unrelated text': Uint8List.fromList(
        List<int>.generate(60000, (i) => 32 + ((i * 7 + i ~/ 61) % 90))),
  };

  group('zstd encode with dictionary', () {
    test('dictionary shorter than 8 bytes gives reference output', () {
      const reference = [
        40,
        181,
        47,
        253,
        32,
        16,
        69,
        0,
        0,
        16,
        97,
        97,
        1,
        0,
        50,
        192,
        2
      ];
      final content = Uint8List(16)..fillRange(0, 16, 97);
      final dictionary = ZstdDictionary([97]);
      final encoded = ZstdEncoder.withDictionary(dictionary, level: 1)
          .encodeBytes(content, checksum: false);
      expect(encoded, reference);
    });

    test('dictionary shorter than 8 bytes still affects compression parameters',
        () {
      final content = Uint8List.fromList(
          List<int>.generate(16383, (i) => (i * 7 + i ~/ 23) % 11));
      final encoder = ZstdEncoder(level: 6, dictionary: Uint8List(7));
      final streamed = OutputMemoryStream();
      encoder.encodeStream(InputMemoryStream(content), streamed,
          checksum: false);
      for (final encoded in [
        encoder.encodeBytes(content, checksum: false),
        streamed.getBytes()
      ]) {
        expect(encoded.length, 236);
        expect(getCrc32(encoded), 2451839013);
      }
    });

    test('literal-only block gets same price as in reference', () {
      final header = base64Decode(
          'N6Qw7DkwAAAMEPhsB/+7OP9CSClTIyAgICAgEAgEAoFAIBAIBAKBQCAQCAQCgUAgEPwD'
          'JECAAAECBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB'
          'AT+AyRAgAABAgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBP4D+/8BAAQAAAAIAAAA');
      final dictionary =
          ZstdDictionary(Uint8List(header.length + 131072)..setAll(0, header));
      final content = _literalBlock();
      for (var level = 16; level <= 22; level++) {
        final encoder = ZstdEncoder.withDictionary(dictionary, level: level);
        final streamed = OutputMemoryStream();
        encoder.encodeStream(InputMemoryStream(content), streamed,
            checksum: false);
        for (final encoded in [
          encoder.encodeBytes(content, checksum: false),
          streamed.getBytes()
        ]) {
          expect(encoded.length, 96795, reason: 'level $level');
          expect(getCrc32(encoded), 458182041, reason: 'level $level');
        }
      }
    });

    test('literal-only block keeps dictionary sequence tables', () {
      List<int> encode(bool literalOnlyFirst) {
        final encoder = ZstdSequencesEncoder()..strategy = zstdStrategyFast;
        encoder.loadDictionary(trained);
        final output = Uint8List(1024);
        if (literalOnlyFirst) {
          encoder.encode(output, 0, ZstdSequenceStore(128));
          encoder.commit();
        }
        encoder.dropOffsetTrust();
        final sequences = ZstdSequenceStore(128);
        for (var i = 0; i < 3; i++) {
          sequences.add(Uint8List(4), 0, i + 1, i + 4, i + 1);
        }
        final length = encoder.encode(output, 0, sequences);
        return output.sublist(0, length);
      }

      expect(encode(true), encode(false));
    });

    test('row matcher does not reuse offsets after dictionary leaves window',
        () {
      final dictionaryBytes = Uint8List(262144);
      var state = 937;
      for (var i = 0; i < dictionaryBytes.length; i++) {
        state = (state * 1664525 + 1013904223) & 0xffffffff;
        dictionaryBytes[i] = state >> 24;
      }
      final dictionary = ZstdDictionary(dictionaryBytes);
      final content = Uint8List(2097153);
      for (var i = 0; i < content.length; i++) {
        content[i] = i < 147456 ? i % 3 : 128 + i % 3;
      }
      content.setRange(1897152, content.length, dictionaryBytes, 50000);
      // ZSTD_compress_usingDict emits the last 65537 bytes as a raw block
      const expected = {
        5: [65762, 1389880943],
        6: [65750, 4184126394],
        7: [65750, 4184126394],
        8: [65750, 4184126394],
      };
      for (final entry in expected.entries) {
        final encoded = ZstdEncoder.withDictionary(dictionary, level: entry.key)
            .encodeBytes(content, checksum: false);
        expect(encoded.length, entry.value[0], reason: 'level ${entry.key}');
        expect(getCrc32(encoded), entry.value[1], reason: 'level ${entry.key}');
      }
    });

    test('optimal parser rejects repeat offsets beyond window', () {
      const window = 1 << 22;
      const distance = window + 76;
      final content = Uint8List(window + 256);
      // Unique four-byte runs prevent earlier matches from replacing the repeat offset
      final digits = List<int>.filled(5, 0);
      var count = 0;
      bool sequence(int at, int period) {
        if (at > 4) {
          if (4 % period == 0) {
            for (var i = 1; i <= period; i++) {
              if (count == content.length) {
                return true;
              }
              content[count++] = 128 + digits[i];
            }
          }
        } else {
          digits[at] = digits[at - period];
          if (sequence(at + 1, period)) {
            return true;
          }
          for (var symbol = digits[at - period] + 1; symbol < 64; symbol++) {
            digits[at] = symbol;
            if (sequence(at + 1, at)) {
              return true;
            }
          }
        }
        return false;
      }

      sequence(1, 1);
      content.setRange(distance, content.length, content, 0);
      final headerSize = trainedBytes.length - trained.content.length;
      final dictionaryBytes = Uint8List(headerSize + window + 4096)
        ..setRange(0, headerSize, trainedBytes);
      ByteData.sublistView(dictionaryBytes)
          .setUint32(headerSize - 12, distance, Endian.little);
      final dictionary = ZstdDictionary(dictionaryBytes);
      final encoded = ZstdEncoder.withDictionary(dictionary, level: 16)
          .encodeBytes(content, checksum: false);
      // ZSTD_compress_usingDict leaves the final out-of-window repeat as literals
      expect(encoded.length, 2465968);
      expect(getCrc32(encoded), 1175055299);
    });

    for (final entry in {'trained': trained, 'raw': raw}.entries) {
      final dictionary = entry.value;
      for (final sample in samples.entries) {
        for (final level in const [1, 3, 5, 9, 12, 15, 19, 22]) {
          test('${entry.key} ${sample.key} at level $level decodes back', () {
            final frame = ZstdEncoder.withDictionary(dictionary, level: level)
                .encodeBytes(sample.value);
            final back = ZstdDecoder.withDictionary(dictionary)
                .decodeBytes(frame, verify: true, throwOnError: true);
            expect(back.length, sample.value.length);
            expect(getCrc32(back), getCrc32(sample.value));
          });
        }
      }
    }

    test('frame stores dictionary id and decodes only with that dictionary',
        () {
      final frame = ZstdEncoder.withDictionary(trained, level: 3)
          .encodeBytes(raw.content);
      expect(trained.id, isNot(0));
      expect(() => ZstdDecoder().decodeBytes(frame, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          () => ZstdDecoder.withDictionary(raw)
              .decodeBytes(frame, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('raw dictionary writes no id, so any decoder with it reads frame', () {
      final frame = ZstdEncoder.withDictionary(raw, level: 3)
          .encodeBytes(Uint8List.fromList(raw.content.sublist(0, 500)));
      final back = ZstdDecoder.withDictionary(raw)
          .decodeBytes(frame, verify: true, throwOnError: true);
      expect(back.length, 500);
    });

    test('frame with dictionary is smaller than without it', () {
      final content = Uint8List.sublistView(raw.content);
      final withDictionary =
          ZstdEncoder.withDictionary(raw, level: 9).encodeBytes(content);
      final without = ZstdEncoder(level: 9).encodeBytes(content);
      expect(withDictionary.length, lessThan(without.length ~/ 4));
    });
  });
}

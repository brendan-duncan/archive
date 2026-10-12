import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/zstd/zstd_web.dart';
import 'package:test/test.dart';

void main() {
  test('streaming jobs and tail send at most 64 KiB per piece', () async {
    final input = Uint8List(600001);
    var state = 1;
    for (var i = 0; i < input.length; i++) {
      state = state * 48271 % 2147483647;
      input[i] = state & 255;
    }
    final parts = await Stream<List<int>>.value(input)
        .transform(const ZstdCodec(
          level: 1,
          multithread:
              ZstdMultithreadOptions.converter(workers: 2, jobSize: 524288),
        ).encoder)
        .toList();
    for (final part in parts) {
      expect(part.length, lessThanOrEqualTo(1 << 16));
    }
    expect(
        ZstdDecoder().decodeBytes(
            Uint8List.fromList(parts.expand((part) => part).toList()),
            verify: true,
            throwOnError: true),
        input);
  });

  for (final entry in {
    6: [694, 1987124167],
    9: [236, 2451839013],
  }.entries) {
    test(
        'contentSize gives loadDictionary output with 7-byte dictionary, '
        'level ${entry.key}', () async {
      final source = Uint8List.fromList(
          List<int>.generate(16383, (i) => (i * 7 + i ~/ 23) % 11));
      final dictionary = ZstdDictionary(Uint8List(7));
      for (final multithread in [
        null,
        const ZstdMultithreadOptions<Uint8List>.converter(workers: 1),
      ]) {
        final encoded = await Stream<List<int>>.fromIterable([
          for (var at = 0; at < source.length; at += 777)
            Uint8List.sublistView(source, at,
                at + 777 < source.length ? at + 777 : source.length),
        ])
            .transform(ZstdEncoderConverter(
                level: entry.key,
                checksum: false,
                dictionary: dictionary,
                contentSize: source.length,
                multithread: multithread))
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        expect(encoded.length, entry.value[0]);
        expect(getCrc32(encoded), entry.value[1]);
        expect(
            ZstdDecoder.withDictionary(dictionary)
                .decodeBytes(encoded, throwOnError: true),
            source);
      }
    });
  }

  test('FSE fixed-point rounding keeps bits beyond JS precision', () {
    const roundUp = [0, 473195, 504333, 520860, 550000, 700000, 750000, 830000];
    const cases = [
      [10, 5, 1, 3],
      [10, 5, 3, 9],
      [10, 5, 5, 15],
      [10, 5, 9, 28],
      [10, 12, 1, 409],
      [10, 12, 3, 1228],
      [10, 12, 5, 2047],
      [10, 12, 9, 3686],
      [131071, 5, 1, 1],
      [131071, 5, 43690, 10],
      [131071, 5, 65535, 15],
      [131071, 5, 131070, 31],
      [131071, 12, 43690, 1365],
      [131071, 12, 131070, 4095],
      [4294967295, 5, 1431655765, 10],
      [4294967295, 5, 2147483647, 15],
      [4294967295, 12, 1431655765, 1365],
      [4294967295, 12, 4294967294, 4095],
    ];
    for (final row in cases) {
      expect(
          ZstdFseScale.normalize(row[0], row[1]).probability(row[2], roundUp),
          row[3],
          reason: '$row');
    }
    final remainder = ZstdFseScale.remainder(131071, 31, 8);
    expect([43690, 32767, 54614].map(remainder.advance), [10, 8, 13]);
  });

  final seed = Uint8List(4096);
  var state = 1;
  for (var i = 0; i < seed.length; i++) {
    state = state * 48271 % 2147483647;
    seed[i] = state & 255;
  }
  final input = Uint8List(400000);
  for (var i = 0; i < input.length; i++) {
    input[i] = seed[i % seed.length];
    if (i % 997 == 0) {
      state = state * 48271 % 2147483647;
      input[i] = state & 255;
    }
  }
  const golden = {
    1: [5795, 278041362],
    2: [5795, 278041362],
    3: [5795, 278041362],
    4: [5795, 278041362],
    5: [5795, 278041362],
    6: [6243, 2774145976],
    9: [6284, 3627928677],
    12: [6284, 3627928677],
    15: [6236, 617795840],
    19: [5785, 3155801168],
    22: [5814, 3822642021],
  };
  for (var level = 1; level <= 22; level++) {
    test('encoder level $level gives same matches and entropy on web', () {
      final encoded =
          ZstdEncoder().encodeBytes(input, level: level, checksum: true);
      if (golden.containsKey(level)) {
        expect([encoded.length, getCrc32(encoded)], golden[level]);
      }
      expect(
          ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true),
          input);
    });
    test('stream of unknown size with dictionary at level $level works on web',
        () {
      final dictionary = ZstdDictionary(seed);
      final held = _Held();
      final stream = ZstdChunkedEncoder(held, level: level);
      for (var at = 0; at < input.length; at += 33333) {
        final end = at + 33333 < input.length ? at + 33333 : input.length;
        stream.addSlice(input, at, end, false);
      }
      stream.close();
      final decoder = ZstdDecoder.withDictionary(dictionary);
      expect(
          ZstdDecoder().decodeBytes(held.bytes.takeBytes(),
              verify: true, throwOnError: true),
          input);
      expect(
          decoder.decodeBytes(
              ZstdEncoder.withDictionary(dictionary, level: level)
                  .encodeBytes(input),
              verify: true,
              throwOnError: true),
          input);
    });
  }
}

class _Held implements Sink<List<int>> {
  final bytes = BytesBuilder();
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void close() {}
}

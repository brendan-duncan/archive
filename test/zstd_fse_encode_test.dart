import 'dart:math';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_bit_reader.dart';
import 'package:archive/src/codecs/zstd/zstd_bit_writer.dart';
import 'package:archive/src/codecs/zstd/zstd_fse.dart';
import 'package:archive/src/codecs/zstd/zstd_fse_encoder.dart';
import 'package:test/test.dart';

/// Normalizes [counts], writes the description and reads it back, checking the
/// two agree
Int16List _roundTripTable(Uint32List counts, int maxSymbol, int maxLog) {
  var total = 0;
  for (var s = 0; s <= maxSymbol; s++) {
    total += counts[s];
  }
  final log = zstdOptimalTableLog(maxLog, total, maxSymbol);
  final normalized = Int16List(maxSymbol + 1);
  expect(zstdNormalizeCount(normalized, counts, total, maxSymbol, log), isTrue);

  var points = 0;
  for (var s = 0; s <= maxSymbol; s++) {
    final value = normalized[s];
    points += value < 0 ? -value : value;
  }
  expect(points, 1 << log, reason: 'points do not add up to the table size');

  final written = Uint8List(512);
  final size = zstdWriteNCount(written, 0, normalized, maxSymbol, log);
  final read = Int16List(maxSymbol + 1);
  final back = readFseDistribution(written, 0, size, read, maxSymbol,
      maxAccuracyLog: maxLog);
  expect(back.accuracyLog, log);
  expect(back.bytesRead, size);
  for (var s = 0; s <= back.maxSymbol; s++) {
    expect(read[s], normalized[s], reason: 'symbol $s');
  }
  for (var s = back.maxSymbol + 1; s <= maxSymbol; s++) {
    expect(normalized[s], 0, reason: 'symbol $s past the last one written');
  }
  return normalized;
}

/// Encodes [symbols] with the table [normalized] describes and decodes them
/// with the decoder's own table
void _roundTripSymbols(
    Int16List normalized, int maxSymbol, int log, List<int> symbols) {
  final ctable = ZstdFseCTable(log, maxSymbol + 1);
  ctable.build(normalized, maxSymbol, log, Uint8List(1 << log),
      Uint16List(maxSymbol + 1), Uint32List(maxSymbol + 2));

  final out = Uint8List(symbols.length * 4 + 64);
  final writer = ZstdBitWriter(ByteData.sublistView(out));
  var state = ctable.initialState(symbols.last);
  for (var i = symbols.length - 2; i >= 0; i--) {
    state = ctable.encode(writer, state, symbols[i]);
    writer.flush();
  }
  writer.add(state, log);
  writer.flush();
  final size = writer.close();

  final table = ZstdFseTable(log);
  buildFseTable(table, normalized, maxSymbol, log, Uint8List(1 << log),
      Uint16List(maxSymbol + 1));
  final reader = ZstdBitReader();
  expect(reader.setStream(out, 0, size), isTrue);
  var decoded = reader.read(log);
  for (var i = 0; i < symbols.length; i++) {
    final row = table.rows[decoded];
    expect(row & 0xff, symbols[i], reason: 'symbol $i of ${symbols.length}');
    if (i + 1 < symbols.length) {
      decoded = (row >>> 16) + reader.read((row >> 8) & 0xff);
      reader.reload();
      expect(reader.isOverrun, isFalse, reason: 'ran out at symbol $i');
    }
  }
}

void main() {
  group('zstd FSE encoder', () {
    test('skewed distribution decodes back', () {
      final counts = Uint32List(36);
      counts[0] = 4000;
      counts[1] = 900;
      counts[2] = 300;
      counts[7] = 60;
      counts[20] = 3;
      counts[35] = 1;
      _roundTripTable(counts, 35, 9);
    });

    test('flat distribution decodes back', () {
      final counts = Uint32List(52);
      for (var s = 0; s < 52; s++) {
        counts[s] = 100;
      }
      _roundTripTable(counts, 51, 9);
    });

    test('long runs of unused symbols decode back', () {
      final counts = Uint32List(52);
      counts[0] = 500;
      counts[1] = 400;
      counts[51] = 300;
      _roundTripTable(counts, 51, 9);
    });

    test('2 symbols decode back', () {
      final counts = Uint32List(4);
      counts[1] = 700;
      counts[3] = 3;
      _roundTripTable(counts, 3, 6);
    });

    test('single symbol with all probability is refused', () {
      final counts = Uint32List(8);
      counts[5] = 1000;
      final normalized = Int16List(8);
      expect(zstdNormalizeCount(normalized, counts, 1000, 7, 6), isFalse);
    });

    test('random distributions decode back, table and symbols', () {
      final random = Random(20260908);
      for (var round = 0; round < 200; round++) {
        final maxSymbol = 1 + random.nextInt(51);
        final maxLog = 6 + random.nextInt(4);
        final counts = Uint32List(maxSymbol + 1);
        var total = 0;
        while (total == 0) {
          total = 0;
          for (var s = 0; s <= maxSymbol; s++) {
            counts[s] = random.nextInt(4) == 0 ? 0 : random.nextInt(500);
            total += counts[s];
          }
        }
        var single = false;
        for (var s = 0; s <= maxSymbol; s++) {
          if (counts[s] == total) {
            single = true;
          }
        }
        if (single || total < 2) {
          continue;
        }

        final log = zstdOptimalTableLog(maxLog, total, maxSymbol);
        final normalized = _roundTripTable(counts, maxSymbol, maxLog);

        final symbols = <int>[];
        for (var s = 0; s <= maxSymbol; s++) {
          if (normalized[s] == 0) {
            continue;
          }
          for (var i = 0; i < counts[s] ~/ 20 + 1; i++) {
            symbols.add(s);
          }
        }
        symbols.shuffle(random);
        _roundTripSymbols(normalized, maxSymbol, log, symbols);
      }
    });
  });
}

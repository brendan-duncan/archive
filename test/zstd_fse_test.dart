@TestOn('vm || wasm')
library;

import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/_zstd_sequences_html.dart' as html;
import 'package:archive/src/codecs/zstd/_zstd_sequences_io.dart' as io;
import 'package:archive/src/codecs/zstd/zstd_constants.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:test/test.dart';

// Rows taken from Appendix A of the zstd format specification, packed as
// symbol | nbBits << 8 | baseline << 16

final expectedLiteralsLength = Uint32List.fromList(const [
  1024,
  1049600,
  2098433,
  1283,
  1284,
  1286,
  1287,
  1289,
  1290,
  1292,
  1550,
  1296,
  1298,
  1299,
  1301,
  1302,
  1304,
  2098457,
  1306,
  1563,
  1565,
  1567,
  2098176,
  1025,
  1282,
  2098436,
  1285,
  2098439,
  1288,
  2098442,
  1291,
  1549,
  2098448,
  1297,
  2098451,
  1300,
  2098454,
  1303,
  1049,
  1049625,
  2098458,
  1564,
  1566,
  3146752,
  1049601,
  2098434,
  2098435,
  2098437,
  2098438,
  2098440,
  2098441,
  2098443,
  2098444,
  1551,
  2098449,
  2098450,
  2098452,
  2098453,
  2098455,
  2098456,
  1571,
  1570,
  1569,
  1568,
]);

final expectedMatchLength = Uint32List.fromList(const [
  1536,
  1025,
  2098434,
  1283,
  1285,
  1286,
  1288,
  1546,
  1549,
  1552,
  1555,
  1558,
  1561,
  1564,
  1567,
  1569,
  1571,
  1573,
  1575,
  1577,
  1579,
  1581,
  1049601,
  1026,
  2098435,
  1284,
  2098438,
  1287,
  1545,
  1548,
  1551,
  1554,
  1557,
  1560,
  1563,
  1566,
  1568,
  1570,
  1572,
  1574,
  1576,
  1578,
  1580,
  2098177,
  3146753,
  1049602,
  2098436,
  2098437,
  2098439,
  2098440,
  1547,
  1550,
  1553,
  1556,
  1559,
  1562,
  1565,
  1588,
  1587,
  1586,
  1585,
  1584,
  1583,
  1582,
]);

final expectedOffset = Uint32List.fromList(const [
  1280,
  1030,
  1289,
  1295,
  1301,
  1283,
  1031,
  1292,
  1298,
  1303,
  1285,
  1032,
  1294,
  1300,
  1282,
  1049607,
  1291,
  1297,
  1302,
  1284,
  1049608,
  1293,
  1299,
  1281,
  1049606,
  1290,
  1296,
  1308,
  1307,
  1306,
  1305,
  1304,
]);

/// The packed row carries the code's own baseline rather than its number, so
/// the number is recovered from the baseline to compare against the appendix
void expectTable(Uint64List rows, int base, Uint32List expected,
    Uint32List baselines, int maxSymbol, String name) {
  final actual = Uint64List.sublistView(rows, base, base + expected.length);
  final codeOf = <int, int>{
    for (var code = 0; code <= maxSymbol; code++) baselines[code]: code
  };
  for (var state = 0; state < expected.length; state++) {
    final row = actual[state];
    final symbol = codeOf[row >> 30];
    final nbBits = (row >> 16) & 0xff;
    final baseline = (row & 0xffff) - base;
    final want = expected[state];
    if (symbol != (want & 0xff) ||
        nbBits != ((want >> 8) & 0xff) ||
        baseline != (want >>> 16)) {
      fail('$name state $state: symbol $symbol bits $nbBits base $baseline, '
          'expected symbol ${want & 0xff} bits ${(want >> 8) & 0xff} '
          'base ${want >>> 16}');
    }
  }
}

void main() {
  test('compressed FSE table with only symbol 0 decodes', () {
    const encoded = [
      40,
      181,
      47,
      253,
      0,
      0,
      77,
      0,
      0,
      8,
      97,
      1,
      100,
      1,
      240,
      3,
      0,
      32
    ];
    expect(ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true),
        [97, 97, 97, 97]);
  });

  final rows = io.ZstdSequences().rows;
  final web = html.ZstdSequences();

  group('predefined FSE tables match specification', () {
    test('literals length table', () {
      expectTable(
          rows,
          zstdPredefinedLiteralsLengthTableBase,
          expectedLiteralsLength,
          zstdLiteralsLengthBaseline,
          zstdLiteralsLengthCodeMax,
          'literals length');
    });
    test('match length table', () {
      expectTable(rows, zstdPredefinedMatchLengthTableBase, expectedMatchLength,
          zstdMatchLengthBaseline, zstdMatchLengthCodeMax, 'match length');
    });
    test('offset table', () {
      expectTable(rows, zstdPredefinedOffsetTableBase, expectedOffset,
          zstdOffsetBaseline, zstdPredefinedOffsetCodeMax, 'offset');
    });

    test('split rows used by web build equal full table rows', () {
      for (var state = zstdBuiltTableRows; state < zstdSeqTableRows; state++) {
        final row = rows[state];
        expect(web.next[state], row & 0xffff, reason: 'next at $state');
        expect(web.nbBits[state], (row >> 16) & 0xff, reason: 'bits at $state');
        expect(web.extraBits[state], (row >> 24) & 0x3f,
            reason: 'extra at $state');
        expect(web.baseline[state], row >> 30, reason: 'baseline at $state');
      }
    });
  });
}

import 'dart:typed_data';

import 'package:archive/src/util/xxh64.dart';
import 'package:test/test.dart';

const _reference = {
  0: '17241709254077376921',
  1: '12208272383309036471',
  3: '6261856666793576441',
  4: '14271086647985540868',
  7: '12663836542954871438',
  8: '4442176141076628448',
  15: '12549904796550154919',
  16: '11644853062034244627',
  31: '5365180931665220769',
  32: '10184845083914585149',
  33: '7118499008196474468',
  63: '6643383451930527103',
  64: '8915644864283660670',
  100: '17266991381171192145',
  255: '3187902827951256350',
  256: '8944139728144044245',
  1000: '11049950332057828661',
  4096: '16289929688763889881',
};

/// The digest is two 32 bit halves, since a JavaScript number cannot hold it
/// whole, and the reference values are decimal
String _digest(Xxh64 hash) =>
    ((BigInt.from(hash.digestHigh) << 32) | BigInt.from(hash.digestLow))
        .toString();

void main() {
  final data = Uint8List(4096);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + 7) & 0xff;
  }

  test('digest matches reference', () {
    for (final entry in _reference.entries) {
      final hash = Xxh64();
      hash.update(data, 0, entry.key);
      expect(_digest(hash), entry.value, reason: 'length ${entry.key}');
    }
  });

  test('input split into pieces gives same digest', () {
    for (final entry in _reference.entries) {
      final size = entry.key;
      for (final chunk in const [1, 5, 7, 32, 33, 64]) {
        final hash = Xxh64();
        for (var at = 0; at < size; at += chunk) {
          final take = at + chunk > size ? size - at : chunk;
          hash.update(data, at, take);
        }
        expect(_digest(hash), entry.value,
            reason: 'length $size in chunks of $chunk');
      }
    }
  });

  test('reset returns used instance to initial state', () {
    final hash = Xxh64();
    hash.update(data, 0, 1000);
    hash.reset();
    hash.update(data, 0, 33);
    expect(_digest(hash), _reference[33]);
  });
}

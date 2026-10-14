import 'dart:typed_data';

import 'package:archive/src/util/sha256.dart';
import 'package:test/test.dart';

const _reference = {
  0: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  1: 'ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879',
  55: '8aa994584139d128848eeebc4e815639ba5ab6e6e39574195a63ac4f14f7c43b',
  56: 'ad574708f75c044c9b85de64cb568ee7711ff4f36448c6242f053ba8f6cc2b63',
  63: '280ed3e8ff1df845b2e7dfe6ac6cee817bef20e783cc65abc41b818b4d2fe076',
  64: 'c6ab9724ade5b6a7a1edfffb12f3aa9181351355af8fd08c919952ad211339dd',
  65: '788367c73c7ddf4c53f65e68cc0d943e6227ab55b0e78ba63ace822b1c6301c0',
  119: '3d610547d68216dedf7435a4fb6260353911f6b3fd3f18805ddb8be285d726fe',
  120: '1f80156a804cb7862ad113e8200e9d74499723e7c7854d5f48776d3148e09656',
  127: '192409cd280e14b743642ad1343fbd3e82d9305de72c078117745a679210cc3d',
  128: 'cc548ca2dec1f6fe4f58b2e27aa9c7521607df1130d140b55a4dad0665302356',
  1000: '5097e7d587352f5097062ae679f37bda5802d9f875aba14c8cb4d1a188ada179',
  4096: 'd41d438c379110c7f7b2c561b1f04f26c1b4549110791f8e022f48974280c13e',
};

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final data = Uint8List(4096);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + 7) & 0xff;
  }

  test('digest matches reference', () {
    for (final entry in _reference.entries) {
      final hash = Sha256();
      hash.update(data, 0, entry.key);
      expect(_hex(hash.digest()), entry.value, reason: 'length ${entry.key}');
    }
  });

  test('digest matches FIPS 180-2 vectors', () {
    expect(
        _hex(Sha256.of(Uint8List.fromList('abc'.codeUnits))),
        'ba7816bf8f01cfea414140de5dae2223'
        'b00361a396177a9cb410ff61f20015ad');
    expect(
        _hex(Sha256.of(Uint8List.fromList(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'
                .codeUnits))),
        '248d6a61d20638b8e5c026930c3e6039'
        'a33ce45964ff2167f6ecedd419db06c1');
  });

  test('input split into pieces gives same digest', () {
    for (final entry in _reference.entries) {
      final size = entry.key;
      for (final chunk in const [1, 5, 7, 63, 64, 65]) {
        final hash = Sha256();
        for (var at = 0; at < size; at += chunk) {
          final take = at + chunk > size ? size - at : chunk;
          hash.update(data, at, take);
        }
        expect(_hex(hash.digest()), entry.value,
            reason: 'length $size in chunks of $chunk');
      }
    }
  });

  test("digest of 1000000 bytes 'a' matches FIPS 180-2", () {
    final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
    expect(
        _hex(Sha256.of(million)),
        'cdc76e5c9914fb9281a1c7e284d73e67'
        'f1809a48a497200e046d39ccc7112cd0');
  });

  test('instance is ready for next input after digest', () {
    final hash = Sha256();
    hash.update(data, 0, 1000);
    hash.digest();
    hash.update(data, 0, 65);
    expect(_hex(hash.digest()), _reference[65]);
  });

  test('reset returns used instance to initial state', () {
    final hash = Sha256();
    hash.update(data, 0, 1000);
    hash.reset();
    hash.update(data, 0, 120);
    expect(_hex(hash.digest()), _reference[120]);
  });
}

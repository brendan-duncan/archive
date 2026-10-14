// ignore_for_file: deprecated_member_use_from_same_package
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/aes.dart';
import 'package:test/test.dart';

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

const _plain = '6bc1bee22e409f96e93d7e117393172a'
    'ae2d8a571e03ac9c9eb76fac45af8e51'
    '30c81c46a35ce411e5fbc1191a0a52ef'
    'f69f2445df4f9b17ad2b417be66c3710';
const _iv = 'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff';

/// NIST SP 800-38A F.5.1, F.5.3 and F.5.5, by key
const _nist = {
  '2b7e151628aed2a6abf7158809cf4f3c': '874d6191b620e3261bef6864990db6ce'
      '9806f66b7970fdff8617187bb9fffdff'
      '5ae4df3edbd5d35e5b4f09020db03eab'
      '1e031dda2fbe03d1792170a0f3009cee',
  '8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b':
      '1abc932417521ca24f2b0459fe7e6e0b'
          '090339ec0aa6faefd5ccc2c6f4ce8e94'
          '1e36b26bd1ebc670d1bd1d665620abf7'
          '4f78a7f6d29809585a97daec58c6b050',
  '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4':
      '601ec313775789a5b7a7f504bbf3d228'
          'f443e3ca4d62b59aca84e990cacaf5c5'
          '2b0930daa23de94ce87017ba2d84988d'
          'dfc9c58db67aada613c2dd08457941a6',
};

void main() {
  test('Aes.processData authenticates the range it was given', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final macKey = Uint8List.fromList(List.generate(32, (i) => 100 + i));
    final data = Uint8List.fromList(List.generate(300, (i) => i * 7 & 0xff));
    final whole = Uint8List.fromList(data.sublist(5, 205));
    final alone = Aes(key, macKey, 32)..processData(whole, 0, whole.length);
    final inPlace = Uint8List.fromList(data);
    final offset = Aes(key, macKey, 32)..processData(inPlace, 5, 200);
    expect(offset.mac, alone.mac);
    expect(inPlace.sublist(5, 205), whole);
  });

  test('output matches NIST SP 800-38A vectors', () {
    for (final entry in _nist.entries) {
      final data = _bytes(_plain);
      AesCtr(_bytes(entry.key), _bytes(_iv)).process(data);
      expect(_hex(data), entry.value, reason: 'key ${entry.key.length * 4}');
    }
  });

  test('decrypting encrypted bytes restores original bytes', () {
    final key = _bytes(_nist.keys.last);
    final data = _bytes(_plain);
    AesCtr(key, _bytes(_iv)).process(data);
    AesCtr(key, _bytes(_iv)).process(data);
    expect(_hex(data), _plain);
  });

  test('input processed in pieces of any length matches NIST vectors', () {
    final key = _bytes(_nist.keys.first);
    for (final piece in const [1, 5, 15, 16, 17, 31, 33]) {
      final data = _bytes(_plain);
      final ctr = AesCtr(key, _bytes(_iv));
      for (var at = 0; at < data.length; at += piece) {
        final end = at + piece < data.length ? at + piece : data.length;
        ctr.process(data, at, end);
      }
      expect(_hex(data), _nist.values.first, reason: 'piece $piece');
    }
  });

  test('little-endian counter matches WinZip key stream', () {
    // Key stream from openssl aes-256-ecb over the counter blocks
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final fromOne = Uint8List(64);
    AesCtr(key, Uint8List(16)..[0] = 1, littleEndianCounter: true)
        .process(fromOne);
    expect(
        _hex(fromOne),
        'c7b519846a11411cd6ac07cb03f801a84ef4b88bebd54953c37ffaf66efaca7b'
        '80c3017e8f89ab315ede32b11e48ab50d5786900334bbaad31a868ca3c29221b');
    final carry = Uint8List(64);
    AesCtr(
            key,
            Uint8List(16)
              ..[0] = 0xff
              ..[1] = 0xff,
            littleEndianCounter: true)
        .process(carry);
    expect(
        _hex(carry),
        '7604c7667f2ee3d62d87ddbb63dfab1472355e14dcb3ba06004648aecc9f75f6'
        '55c88b2088550f02e256bb586438631567f1a1c590ddd30d63a93f7c415cc372');
  });

  test('counter wraps to zero when all 16 bytes overflow', () {
    // Key stream from openssl aes-128-ecb over ff..ff, 00..00 and one
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Uint8List(16)..fillRange(0, 16, 0xff);
    final bigEndian = Uint8List(48);
    AesCtr(key, iv).process(bigEndian);
    expect(
        _hex(bigEndian),
        '3c441f32ce07822364d7a2990e50bb13c6a13b37878f5b826f4f8162a1c8d879'
        '7346139595c0b41e497bbde365f42d0a');
    final littleEndian = Uint8List(48);
    AesCtr(key, iv, littleEndianCounter: true).process(littleEndian);
    expect(
        _hex(littleEndian),
        '3c441f32ce07822364d7a2990e50bb13c6a13b37878f5b826f4f8162a1c8d879'
        'e37cd363dd7c87a09aff0e3e60e09c82');
  });

  test('key or iv of wrong length throws ArgumentError', () {
    expect(() => AesCtr(Uint8List(20), Uint8List(16)), throwsArgumentError);
    expect(() => AesCtr(Uint8List(16), Uint8List(12)), throwsArgumentError);
  });

  test('deprecated AesDecrypt gives 4.5.1 output for every key size', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i * 7 + 1));
    final expected = {
      AesDecrypt.aes128: ('d32d0ad52d4ed58b6317deed012136d826d691f7ff4777c2'
          '2ecdf8e2f91b91cf443ff02f99db97a3', 3369014201),
      AesDecrypt.aes192: ('4b15aef6ff6dcbd545d8d06d006bc0ecf00395b8df3e963f'
          '3dc9e310f1cc63f69d499fbd0b579419', 3585951987),
      AesDecrypt.aes256: ('f427ca4a77eb2d14a5d4ab8ddb8b34c6528c221b4162af68'
          'afafcc3c2de7d931e272c24cb20eb662', 1934873602),
    };
    for (final MapEntry(key: mode, value: (hex, crc)) in expected.entries) {
      final data = Uint8List.fromList(List.generate(40, (i) => i * 3));
      AesDecrypt(key, mode: mode).decryptCrt(data);
      expect(_hex(data), hex, reason: 'mode $mode');

      final decrypt = AesDecrypt(key, mode: mode);
      for (var call = 0; call < 2; call++) {
        final big = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
        decrypt.decryptCrt(big);
        expect(getCrc32(big), crc, reason: 'mode $mode, call $call');
      }
    }
  });
}

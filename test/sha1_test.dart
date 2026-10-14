import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/src/util/sha1.dart';
import 'package:test/test.dart';

const _reference = {
  0: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
  1: '5d1be7e9dda1ee8896be5b7e34a85ee16452a7b4',
  55: '749bbefb28edc4638b28b2b9a9e03ab9a4032b90',
  56: 'a5b6e9c29d201c774753ff8e7fb64931656f5e63',
  63: 'd1a454409359fc372b4d22b3cea6488d6ba1be00',
  64: '39a0d8b645ad85f1f976731ed112ac9455e28b78',
  65: 'd0c96e18890114a14716e9686528d2e3fdba8d9e',
  119: '562ecf8a430f8e1056e3619bae33628e9a1d0a4e',
  120: '353f6d2bf0e91aa91b74a2e0b3f297510f7d825f',
  127: 'bebc42d2d3d1e5fb8ad8895c2dcef2d68a6c279a',
  128: '0060f2a7e34b6e4d459f560197ef93243732a400',
  1000: '414475341017ec91703435a6f290324818f983e9',
  4096: '2c177f7cc0e199dab44868ac2d42a03814e38e75',
};

/// HMAC-SHA1 from Python's hmac, by key length and then message length. The
/// inner hash starts 64 bytes in, so the padding boundaries of a message move
/// to 55 and 56, 119 and 120
const _hmacReference = {
  0: {
    0: 'fbdb1d1b18aa6c08324b7d64b71fb76370690e1d',
    55: '2d1615d3d1ff9812618435bd86e8d3cf8524e2bf',
    56: '47e43d533b9ddb00c6dc91337360c53e2e81d0be',
    63: 'fe11f210fcdbd2dba17f5b3806bab1da520bff51',
    64: 'c84fff9811c9c95b55e79fe421e0921e2ea4272d',
    119: '3ec8799076431ae2a2d6faeb3f216d58152338a4',
    120: 'e0247b6c0776d60f360c04e497ff9d49fdc4c8e9',
  },
  63: {
    0: 'd5b486cd9b41be1c1cebe2687842be6fa42f45a6',
    55: '01cbc088a3429ed1f3f51ea807a6264bcd6e7152',
    56: 'ca151a47ab65756921ea7dcc869bea2d5539cf47',
    63: '0228d5e59626c664320f9ce8a8773e5cd72cb152',
    64: 'cf4d27b7df19c041b44de6e27777be427dede5df',
    119: 'c133ee9844b68e147cfbbb77abcd4be8e7e8eea9',
    120: '8b253fa9108755d2166804b02035a817cbcc1aba',
  },
  64: {
    0: '354dbfdb062a384555ff4121f0612066a092940f',
    55: '8c3749d3ac2c7e20430ed1910ee23c7dc7aa38d6',
    56: '273ca23061ff7f046200c1b363a36a87b1c08e79',
    63: '1bfb200c24d80e4ab8b1396b959a93534edb9079',
    64: '56d253ef5eaf189da08b3e75c00720cbe5cbabaf',
    119: '61d53f6d442064ab95eb25ab3dd9db307630231d',
    120: '5f61c1c693c322820c6267ca5e1a89b0ce4b6da6',
  },
  65: {
    0: '3271e26f61b0544f6bf4b703dc1c09755368ad2c',
    55: 'c2f0b0b0de7f756a8a0cc3c6482b2752b43915cd',
    56: 'c73f60aed4e48241542496802c3f5a8bdb526311',
    63: '9e80a381903493b3a2c7a520c6ad3df7a8fafb3f',
    64: '506c828a677d7d307a7fac752866154ffac59fec',
    119: '41222159389ad403834bcc772295cbbeeee8ac27',
    120: '2664402183a042b3939cd49af834e1dc5775eee1',
  },
};

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _bytes(String text) => Uint8List.fromList(latin1.encode(text));

String _hmac(Uint8List key, Uint8List data) {
  final out = Uint8List(HmacSha1.macSize);
  HmacSha1(key)
    ..update(data, 0, data.length)
    ..finish(out, 0);
  return _hex(out);
}

void main() {
  final data = Uint8List(4096);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + 7) & 0xff;
  }

  test('digest matches reference', () {
    for (final entry in _reference.entries) {
      final hash = Sha1();
      hash.update(data, 0, entry.key);
      expect(_hex(hash.digest()), entry.value, reason: 'length ${entry.key}');
    }
  });

  test('digest matches FIPS 180-2 vectors', () {
    expect(_hex((Sha1()..update(_bytes('abc'), 0, 3)).digest()),
        'a9993e364706816aba3e25717850c26c9cd0d89d');
    final long =
        _bytes('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq');
    expect(_hex((Sha1()..update(long, 0, long.length)).digest()),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
  });

  test('input split into pieces gives same digest', () {
    for (final entry in _reference.entries) {
      final size = entry.key;
      for (final chunk in const [1, 5, 7, 63, 64, 65]) {
        final hash = Sha1();
        for (var at = 0; at < size; at += chunk) {
          final take = at + chunk > size ? size - at : chunk;
          hash.update(data, at, take);
        }
        expect(_hex(hash.digest()), entry.value,
            reason: 'length $size, chunk $chunk');
      }
    }
  });

  test('HMAC-SHA1 matches RFC 2202 vectors', () {
    expect(_hmac(Uint8List(20)..fillRange(0, 20, 0x0b), _bytes('Hi There')),
        'b617318655057264e28bc0b6fb378c8ef146be00');
    expect(_hmac(_bytes('Jefe'), _bytes('what do ya want for nothing?')),
        'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79');
    expect(
        _hmac(Uint8List(20)..fillRange(0, 20, 0xaa),
            Uint8List(50)..fillRange(0, 50, 0xdd)),
        '125d7342b9ac11cd91a39af48aa17b4f63f175d3');
    expect(
        _hmac(Uint8List.fromList(List.generate(25, (i) => i + 1)),
            Uint8List(50)..fillRange(0, 50, 0xcd)),
        '4c9007f4026250c6bc8414f9bf50c86c2d7235da');
    final bigKey = Uint8List(80)..fillRange(0, 80, 0xaa);
    expect(
        _hmac(bigKey,
            _bytes('Test Using Larger Than Block-Size Key - Hash Key First')),
        'aa4ae5e15272d00e95705637ce8a3b55ed402112');
    expect(
        _hmac(
            bigKey,
            _bytes('Test Using Larger Than Block-Size Key and Larger '
                'Than One Block-Size Data')),
        'e8e99d0f45237d786d6bbaa7965c7808bbff1a91');
  });

  test('reused HMAC-SHA1 gives same MAC for same message', () {
    final mac = HmacSha1(_bytes('Jefe'));
    final text = _bytes('what do ya want for nothing?');
    final out = Uint8List(HmacSha1.macSize);
    for (var i = 0; i < 3; i++) {
      mac
        ..update(text, 0, 10)
        ..update(text, 10, text.length - 10)
        ..finish(out, 0);
      expect(_hex(out), 'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79');
    }
  });

  test('PBKDF2-HMAC-SHA1 matches RFC 6070 vectors', () {
    String derive(String password, String salt, int count, int length) =>
        _hex(pbkdf2HmacSha1(_bytes(password), _bytes(salt), count, length));
    expect(derive('password', 'salt', 1, 20),
        '0c60c80f961f0e71f3a9b524af6012062fe037a6');
    expect(derive('password', 'salt', 2, 20),
        'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957');
    expect(derive('password', 'salt', 4096, 20),
        '4b007901b765489abead49d926f721d065a429c1');
    expect(
        derive('passwordPASSWORDpassword',
            'saltSALTsaltSALTsaltSALTsaltSALTsalt', 4096, 25),
        '3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038');
    expect(derive('pass\x00word', 'sa\x00lt', 4096, 16),
        '56fa6aa75548099dcc37d7f03425e0c3');
  });

  test('PBKDF2-HMAC-SHA1 with iterations below 1 throws ArgumentError', () {
    for (final iterations in [0, -1]) {
      for (final length in [0, 1, 66]) {
        expect(
            () => pbkdf2HmacSha1(
                _bytes('password'), _bytes('salt'), iterations, length),
            throwsArgumentError,
            reason: 'iterations $iterations, length $length');
      }
    }
  });

  test('PBKDF2-HMAC-SHA1 derives 66-byte AES-256 zip key', () {
    expect(
        _hex(pbkdf2HmacSha1(_bytes('secret'),
            Uint8List.fromList(List.generate(16, (i) => i)), 1000, 66)),
        'b054b25cf15c5e093100214b7cbd9d49b6e163a979efc91aa818b8a2f664ee1d'
        '4315c73829e75ef42f5b8942f6d1d1dff97ddfcfa912c2a63a87d24a1948b787'
        'a336');
  });

  test('HMAC-SHA1 matches reference around padding boundaries', () {
    for (final byKey in _hmacReference.entries) {
      final key =
          Uint8List.fromList(List.generate(byKey.key, (i) => (i * 17 + 3)));
      for (final entry in byKey.value.entries) {
        expect(
            _hmac(key, Uint8List.sublistView(data, 0, entry.key)), entry.value,
            reason: 'key ${byKey.key}, message ${entry.key}');
      }
    }
  });

  test("digest of 1000000 bytes 'a' matches FIPS 180-2", () {
    final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
    expect(_hex((Sha1()..update(million, 0, million.length)).digest()),
        '34aa973cd4c4daa4f61eeb2bdbad27316534016f');
  });

  test('instance is ready for next input after digest', () {
    final hash = Sha1();
    hash.update(data, 0, 1000);
    hash.digest();
    hash.update(data, 0, 65);
    expect(_hex(hash.digest()), _reference[65]);
  });

  test('reset returns used instance to initial state', () {
    final hash = Sha1();
    hash.update(data, 0, 1000);
    hash.reset();
    hash.update(data, 0, 120);
    expect(_hex(hash.digest()), _reference[120]);
  });
}

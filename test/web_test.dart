import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('zlib web', () {
    test('encode/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoder().encodeBytes(origData);
      final uncompressed = ZLibDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('an input too short for a header is refused, not thrown', () {
      // Without a gzip header the gzip decoder falls back to zlib, whose own
      // two byte header was read unchecked
      final short = Uint8List(1);
      expect(
          ZLibDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
    });

    test('decodeStream with verify reads little-endian input', () {
      final origData = Uint8List.fromList(List.generate(5000, (i) => i * 7));
      final compressed = ZLibEncoder().encodeBytes(origData);
      final out = OutputMemoryStream();
      expect(
          ZLibDecoder()
              .decodeStream(InputMemoryStream(compressed), out, verify: true),
          isTrue);
      compareBytes(out.getBytes(), origData);
    });
  });

  group('gzip web', () {
    final buffer = Uint8List(10000);
    for (var i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('encode/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoder().encodeBytes(origData);
      final uncompressed = GZipDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('verify checks the member CRC', () {
      final compressed = GZipEncoder().encodeBytes(buffer);
      expect(GZipDecoderWeb().decodeBytes(compressed, verify: true).length,
          equals(buffer.length));

      // The stored checksum, not the data: the length still matches, so only
      // the checksum is left to notice
      final damaged = Uint8List.fromList(compressed);
      damaged[damaged.length - 8] ^= 0xff;
      expect(
          () => GZipDecoderWeb().decodeStream(
              InputMemoryStream(damaged), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
      // A second pass over the output, so without verify it is not read
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(damaged), OutputMemoryStream()),
          isTrue);
    });

    test('damage is reported by return value, not thrown', () {
      // These used to come out as a RangeError from inside the decoder
      final compressed = GZipEncoder().encodeBytes(buffer);
      // Bytes that damage a match into reaching back past the output
      for (final at in [18, 19, 20, 21, 22, 23, 154, 158, 164]) {
        final damaged = Uint8List.fromList(compressed);
        damaged[at] ^= 0xff;
        expect(
            GZipDecoderWeb()
                .decodeStream(InputMemoryStream(damaged), OutputMemoryStream()),
            isFalse,
            reason: 'byte $at');
      }

      // A header whose optional fields claim more than the input holds
      final short = Uint8List.fromList(compressed.take(12).toList());
      short[3] = 0x1f; // extra, name, comment and hcrc all present
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(short), OutputMemoryStream()),
          isFalse);
    });

    test('damage is a return value with a file output too', () {
      // Behind a file output a match reaching back past the start used to
      // seek to a negative position and throw, where the memory output threw
      // a RangeError that was caught. Inflate now refuses the match itself
      final compressed = GZipEncoder().encodeBytes(buffer);
      final path = '$testOutputPath/damaged.bin';
      for (final at in [18, 19, 20, 21, 22, 23, 154, 158, 164]) {
        final damaged = Uint8List.fromList(compressed);
        damaged[at] ^= 0xff;
        // A small buffer, so the output has been flushed by the time the
        // bad match arrives
        final out = OutputFileStream(path, bufferSize: 64);
        expect(GZipDecoderWeb().decodeStream(InputMemoryStream(damaged), out),
            isFalse,
            reason: 'byte $at');
        out.closeSync();
      }
    }, testOn: 'vm');

    test('multiblock', () async {
      final compressedData = [
        ...GZipEncoder().encodeBytes([1, 2, 3]),
        ...GZipEncoder().encodeBytes([4, 5, 6])
      ];
      final decodedData =
          GZipDecoderWeb().decodeBytes(compressedData, verify: true);
      compareBytes(decodedData, [1, 2, 3, 4, 5, 6]);
    });

    test('encode/decode', () {
      final compressed = GZipEncoder().encodeBytes(buffer);
      final decompressed = GZipDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });
  });

  group('tar web', () {
    // On the web an int is a double and the bitwise operators are 32 bit, so
    // a base 256 header field has to be read with arithmetic to survive the
    // trip. 9437184000 needs 34 bits and would come back truncated otherwise
    test('base 256 size', () {
      final h = Uint8List(1024);
      h.setRange(0, 5, 'a.txt'.codeUnits);
      h.setRange(124, 136, [0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x32, 0x80, 0, 0]);
      h[156] = 0x30; // normal file
      h.setRange(257, 263, 'ustar '.codeUnits);

      final decoder = TarDecoder();
      decoder.decodeBytes(h, storeData: false);
      expect(decoder.files.length, equals(1));
      expect(decoder.files[0].fileSize, equals(9437184000));
    });
  });

  group('zip', () {
    test('round trips', () {
      // The web zlib encoder left the zip encoder's output big-endian, so
      // every header after the first entry's data was written backwards and
      // the zip decoded to nothing.
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'hello hello hello'))
        ..add(ArchiveFile.string('b.txt', 'world'));
      final decoded =
          ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(archive));
      expect(decoded.map((f) => f.name), ['a.txt', 'b.txt']);
      expect(utf8.decode(decoded[0].readBytes()!), 'hello hello hello');
      expect(utf8.decode(decoded[1].readBytes()!), 'world');
    });

    test('zlib encoding leaves the output byte order alone', () {
      final output = OutputMemoryStream();
      ZLibEncoder()
          .encodeStream(InputMemoryStream(utf8.encode('hello')), output);
      expect(output.byteOrder, ByteOrder.littleEndian);
    });
  });

  group('zip on web', () {
    test('ZipEncoder and zipCodec are created without Random.secure', () {
      // Random.secure() throws on dart2js and Node, and the field used to be
      // eager, so no ZipEncoder and no zipCodec could be built at all there
      expect(ZipEncoder.new, returnsNormally);
      expect(() => const ZipCodec().encoder, returnsNormally);
      final zip = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      expect(ZipDecoder().decodeBytes(zip).files.single.readBytes(),
          'hello'.codeUnits);
    });

    test('deflated entry whose last code ends at data end decodes whole', () {
      final data = [155, 48, 113, 210, 228, 41, 0];
      final content = [0x90, 0x91, 0x92, 0x93, 0x94];
      final crc = getCrc32(content);
      final zip = OutputMemoryStream()
        ..writeUint32(0x04034b50)
        ..writeUint16(20)
        ..writeUint16(0)
        ..writeUint16(8)
        ..writeUint32(0)
        ..writeUint32(crc)
        ..writeUint32(data.length)
        ..writeUint32(content.length)
        ..writeUint16(1)
        ..writeUint16(0)
        ..writeBytes('a'.codeUnits)
        ..writeBytes(data);
      final central = zip.length;
      zip
        ..writeUint32(0x02014b50)
        ..writeUint16(20)
        ..writeUint16(20)
        ..writeUint16(0)
        ..writeUint16(8)
        ..writeUint32(0)
        ..writeUint32(crc)
        ..writeUint32(data.length)
        ..writeUint32(content.length)
        ..writeUint16(1)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint32(0)
        ..writeUint32(0)
        ..writeBytes('a'.codeUnits);
      final size = zip.length - central;
      zip
        ..writeUint32(0x06054b50)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(1)
        ..writeUint16(1)
        ..writeUint32(size)
        ..writeUint32(central)
        ..writeUint16(0);
      expect(ZipDecoder().decodeBytes(zip.getBytes()).files.single.readBytes(),
          content);
    });
  });
  group('zip on web', () {
    test('ZipCrypto keys decrypt same as on VM', () {
      final cases = <(String, String, String)>[
        (
          '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',
          '12345',
          'hello.txt:11:222957957'
        ),
        (
          'UEsDBBQAAQAAAAAAAABcAaBLHAAAABAAAAAFAAAAYS50eHQQf/htznZgJvuDeim31m3Mgn6qKbuRkbRDmF/2UEsBAhQAFAABAAAAAAAAAFwBoEscAAAAEAAAAAUAAAAAAAAAAAAAAAAAAAAAAGEudHh0UEsFBgAAAAABAAEAMwAAAD8AAAAAAA==',
          'pässwort',
          'a.txt:16:1268777308'
        ),
        (
          'UEsDBBQACQAIADOaOl0AAAAAAAAAAAAAAAAFACAAaC50eHR1eAsAAQT1AQAABBQAAABVVA0ABzL+t2pV/rdqMv63alHvrXOvoF6mZIBc6lwRm3KvqRvoUEsHCCAwOjYUAAAABgAAAFBLAQIUAxQACQAIADOaOl0gMDo2FAAAAAYAAAAFABgAAAAAAAAAAACkgQAAAABoLnR4dHV4CwABBPUBAAAEFAAAAFVUBQABMv63alBLBQYAAAAAAQABAEsAAABnAAAAAAA=',
          'pässwort',
          'h.txt:6:909783072'
        ),
        (
          'UEsDBBQACQAIABFTPF0wjM/gTAAAAGUAAAAFABwAZS5iaW5VVAkAA0IkumpCJLpqdXgLAAEE9QEAAAQUAAAADw/yhVbSH6eTzFYSzCByDrY4RUNkZ4iDofowNRuCnxiSGd2XgVUhxwCKEkDp+K+71PGreSGcvpT2u2fpkZir37Uxl2sVuGKRGOpbS1BLBwgwjM/gTAAAAGUAAABQSwECHgMUAAkACAARUzxdMIzP4EwAAABlAAAABQAYAAAAAAABAAAApIEAAAAAZS5iaW5VVAUAA0Ikump1eAsAAQT1AQAABBQAAABQSwUGAAAAAAEAAQBLAAAAmwAAAAAA',
          '密码',
          'e.bin:101:3771698224'
        ),
        (
          'UEsDBAoACQAAALFSPF0z0TwDcAAAAGQAAAAFABwAZS5iaW5VVAkAA40jumqNI7pqdXgLAAEE9QEAAAQUAAAADWHf35BkcaRNND2S6tbyUc2wXdo9VJtE/6FQyrwW48u2tTTySwkW63G3IUaOuBKc2e3T+gp2uqyvV2IaSw4BxywHhj0cDliV2R7s1MyZmlapVzSuHVQdhCiRhDq8TidQBAGAY4toE9KtoIaLWNonbVBLBwgz0TwDcAAAAGQAAABQSwECHgMKAAkAAACxUjxdM9E8A3AAAABkAAAABQAYAAAAAAAAAAAApIEAAAAAZS5iaW5VVAUAA40jump1eAsAAQT1AQAABBQAAABQSwUGAAAAAAEAAQBLAAAAvwAAAAAA',
          'päss',
          'e.bin:100:54317363'
        ),
      ];
      for (final (packed, password, expected) in cases) {
        final archive = ZipDecoder().decodeBytes(base64.decode(packed),
            password: password, verify: true);
        final entry = archive.files.firstWhere((file) => file.isFile);
        final bytes = entry.readBytes()!;
        expect('${entry.name}:${bytes.length}:${getCrc32(bytes)}', expected);
      }
    });
  });
}

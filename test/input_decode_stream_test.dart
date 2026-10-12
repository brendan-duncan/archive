import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

/// Compressible, but not trivially so.
Uint8List sample(int length) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (out.length < length) {
    out.add(utf8.encode('line ${i * 7919 % 1013} of the sample text, '
        'repeated with a twist ${i % 23}\n'));
    i++;
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// Reads [stream] to its end the way a consumer would, in chunks.
Uint8List readAll(InputStream stream, [int chunk = 1000]) {
  final out = BytesBuilder(copy: false);
  while (!stream.isEOS) {
    final bytes = stream.readBytes(chunk).toUint8List();
    if (bytes.isEmpty) {
      break;
    }
    out.add(bytes);
  }
  return out.takeBytes();
}

/// Produces [data] in chunks of [chunkSize] bytes.
class _ListDecoder extends ChunkDecoder {
  final Uint8List data;
  static const chunkSize = 1000;
  int _pos = 0;
  bool throwAt;

  _ListDecoder(this.data, {this.throwAt = false});

  @override
  bool decodeChunk(OutputStream output) {
    if (_pos >= data.length) {
      return false;
    }
    if (throwAt && _pos >= data.length ~/ 2) {
      throw ArchiveException('Bad data');
    }
    final end = _pos + chunkSize > data.length ? data.length : _pos + chunkSize;
    output.writeBytes(Uint8List.sublistView(data, _pos, end));
    _pos = end;
    return _pos < data.length;
  }
}

void main() {
  group('InputDecodeStream', () {
    final data = sample(3 * 1024 * 1024);

    test('reads what the decoder produces', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      compareBytes(readAll(stream, 4096), data);
      expect(stream.isEOS, isTrue);
      expect(stream.readByte(), 0);
    });

    test('readByte and the multi-byte reads', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      expect(stream.readByte(), data[0]);
      expect(stream.readUint16(), data[1] | (data[2] << 8));
      expect(stream.readUint32(),
          data[3] | (data[4] << 8) | (data[5] << 16) | (data[6] << 24));
      expect(stream.position, 7);
    });

    test('views read their part when they are read', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      final header = stream.readBytes(512);
      final content = stream.readBytes(100000);
      stream.skip(12);
      // Nothing has been decoded yet. Read in order, as a tar decoder does,
      // since the window slides past what is behind a read.
      compareBytes(header.toUint8List(), data.sublist(0, 512));
      expect(content.length, 100000);
      compareBytes(content.toUint8List(), data.sublist(512, 100512));
      expect(stream.position, 100524);
      expect(stream.readByte(), data[100524]);
    });

    test('a view ends where it was told to', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      stream.skip(1000);
      final view = stream.readBytes(2500);
      expect(view.length, 2500);
      expect(view.isEOS, isFalse);
      compareBytes(readAll(view, 700), data.sublist(1000, 3500));
      expect(view.isEOS, isTrue);
      expect(view.length, 0);
      // A view past the end of the data is short.
      stream.setPosition(data.length - 10);
      final tail = stream.readBytes(100);
      expect(tail.length, 100);
      expect(tail.toUint8List().length, 10);
    });

    test('peeking and subsets do not move the position', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      stream.skip(5000);
      compareBytes(
          stream.peekBytes(16).toUint8List(), data.sublist(5000, 5016));
      compareBytes(stream.peekBytes(16, offset: 4).toUint8List(),
          data.sublist(5004, 5020));
      compareBytes(stream.subset(position: 10, length: 20).toUint8List(),
          data.sublist(10, 30));
      expect(stream.position, 5000);
    });

    test('rewinding within the window', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      final first = stream.readBytes(3000).toUint8List();
      stream.rewind(1000);
      compareBytes(stream.readBytes(1000).toUint8List(), first.sublist(2000));
    });

    test('data the window has slid past cannot be read', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      final early = stream.readBytes(100);
      stream.skip(2 * 1024 * 1024);
      stream.readBytes(100000).toUint8List();
      expect(() => early.toUint8List(), throwsA(isA<ArchiveException>()));
    });

    test('keepBehind keeps data behind the read position', () {
      final stream = InputDecodeStream(_ListDecoder(data), keepBehind: 300000);
      stream.skip(2 * 1024 * 1024);
      stream.readBytes(100000).toUint8List();
      stream.rewind(300000);
      compareBytes(stream.readBytes(10).toUint8List(),
          data.sublist(2 * 1024 * 1024 - 200000, 2 * 1024 * 1024 - 199990));
    });

    test('length of the whole stream decodes the rest', () {
      final stream = InputDecodeStream(_ListDecoder(data));
      stream.skip(100);
      expect(stream.length, data.length - 100);
      compareBytes(stream.toUint8List(), data.sublist(100));
    });

    test('a failing decoder throws from the read', () {
      final stream = InputDecodeStream(_ListDecoder(data, throwAt: true));
      expect(stream.readBytes(1000).toUint8List().length, 1000);
      expect(() => readAll(stream), throwsA(isA<ArchiveException>()));
    });

    test('an empty decoder', () {
      final stream = InputDecodeStream(_ListDecoder(Uint8List(0)));
      expect(stream.isEOS, isTrue);
      expect(stream.length, 0);
      expect(stream.readBytes(10).toUint8List(), isEmpty);
    });
  });

  group('decodeLazy', () {
    final data = sample(3 * 1024 * 1024);

    test('gzip', () {
      final gz = GZipEncoder().encodeBytes(data);
      for (final decoder in [
        GZipDecoder().decodeLazy(InputMemoryStream(gz)),
        const GZipDecoderWeb().decodeLazy(InputMemoryStream(gz)),
      ]) {
        compareBytes(readAll(decoder, 64 * 1024), data);
      }
    });

    test('gzip, two members', () {
      final gz = Uint8List.fromList(GZipEncoder().encodeBytes(data) +
          GZipEncoder().encodeBytes(data.sublist(0, 1000)));
      for (final decoder in [
        GZipDecoder().decodeLazy(InputMemoryStream(gz)),
        const GZipDecoderWeb().decodeLazy(InputMemoryStream(gz)),
      ]) {
        compareBytes(readAll(decoder), data + data.sublist(0, 1000));
      }
    });

    test('gzip, truncated', () {
      final gz = GZipEncoder().encodeBytes(data);
      final cut = gz.sublist(0, gz.length ~/ 2);
      for (final decoder in [
        GZipDecoder().decodeLazy(InputMemoryStream(cut)),
        const GZipDecoderWeb().decodeLazy(InputMemoryStream(cut)),
      ]) {
        expect(() => readAll(decoder), throwsA(isA<ArchiveException>()));
      }
      // Cut inside the trailer, so all of the data decodes.
      final almost = gz.sublist(0, gz.length - 3);
      for (final decoder in [
        GZipDecoder().decodeLazy(InputMemoryStream(almost)),
        const GZipDecoderWeb().decodeLazy(InputMemoryStream(almost)),
      ]) {
        expect(() => readAll(decoder), throwsA(isA<ArchiveException>()));
      }
    });

    test('gzip, not gzip', () {
      for (final decoder in [
        GZipDecoder().decodeLazy(InputMemoryStream(data.sublist(0, 100))),
        const GZipDecoderWeb()
            .decodeLazy(InputMemoryStream(data.sublist(0, 100))),
      ]) {
        expect(() => readAll(decoder), throwsA(isA<Exception>()));
      }
    });

    test('web gzip and zlib check the trailer checksum with verify', () {
      final gz = GZipEncoder().encodeBytes(data);
      final z = ZLibEncoder().encodeBytes(data);
      final badGz = Uint8List.fromList(gz)..[gz.length - 8] ^= 0xff;
      final badZ = Uint8List.fromList(z)..[z.length - 1] ^= 0xff;
      InputStream gzip(bool verify) => const GZipDecoderWeb()
          .decodeLazy(InputMemoryStream(badGz), verify: verify);
      InputStream zlib(bool verify) => const ZLibDecoderWeb()
          .decodeLazy(InputMemoryStream(badZ), verify: verify);
      for (final decode in [gzip, zlib]) {
        compareBytes(readAll(decode(false), 4096), data);
        expect(() => readAll(decode(true), 4096),
            throwsA(isA<ArchiveChecksumException>()));
      }
    });

    test('zlib', () {
      for (final raw in [false, true]) {
        final z =
            raw ? Deflate(data).getBytes() : ZLibEncoder().encodeBytes(data);
        for (final decoder in [
          ZLibDecoder().decodeLazy(InputMemoryStream(z), raw: raw),
          const ZLibDecoderWeb().decodeLazy(InputMemoryStream(z), raw: raw),
        ]) {
          compareBytes(readAll(decoder, 4096), data);
        }
      }
    });

    test('zlib, damaged data throws ArchiveException without verify', () {
      final z = ZLibEncoder().encodeBytes(data);
      // Block type 3 is reserved, so deflate data is invalid
      final wrongData = Uint8List.fromList(z)..[2] = 0x07;
      for (final decoder in [
        ZLibDecoder().decodeLazy(InputMemoryStream(wrongData)),
        const ZLibDecoderWeb().decodeLazy(InputMemoryStream(wrongData)),
      ]) {
        expect(() => readAll(decoder, 4096), throwsA(isA<ArchiveException>()));
      }
    });

    test('zlib, wrong checksum with verify', () {
      final z = ZLibEncoder().encodeBytes(data);
      final wrongSum = Uint8List.fromList(z)..[z.length - 1] ^= 0xff;
      final wrongData = Uint8List.fromList(z)..[z.length ~/ 2] ^= 0x55;
      final cut = z.sublist(0, z.length - 3);
      for (final input in [wrongSum, wrongData, cut]) {
        for (final decoder in [
          ZLibDecoder().decodeLazy(InputMemoryStream(input), verify: true),
          const ZLibDecoderWeb()
              .decodeLazy(InputMemoryStream(input), verify: true),
        ]) {
          expect(
              () => readAll(decoder, 4096), throwsA(isA<ArchiveException>()));
        }
      }
    });

    test('zstd', () {
      final z = ZstdEncoder().encodeBytes(data, checksum: true);
      final decoder =
          ZstdDecoder().decodeLazy(InputMemoryStream(z), verify: true);
      compareBytes(readAll(decoder, 64 * 1024), data);

      final cut = z.sublist(0, z.length ~/ 2);
      expect(() => readAll(ZstdDecoder().decodeLazy(InputMemoryStream(cut))),
          throwsA(isA<ArchiveException>()));
    });

    test('bzip2', () {
      final bz = BZip2Encoder().encodeBytes(data);
      final decoder =
          BZip2Decoder().decodeLazy(InputMemoryStream(bz), verify: true);
      compareBytes(readAll(decoder, 64 * 1024), data);

      final cut = bz.sublist(0, bz.length ~/ 2);
      expect(() => readAll(BZip2Decoder().decodeLazy(InputMemoryStream(cut))),
          throwsA(isA<ArchiveException>()));
      // Cut between blocks, before the end of stream marker.
      final decoder2 = BZip2Decoder().decodeLazy(InputMemoryStream(cut));
      decoder2.readBytes(100).toUint8List();
      expect(() => readAll(decoder2), throwsA(isA<ArchiveException>()));
    });

    test('xz', () {
      final x = XZEncoder().encodeBytes(data);
      compareBytes(
          readAll(XZDecoder().decodeLazy(InputMemoryStream(x), verify: true),
              64 * 1024),
          data);

      final cut = x.sublist(0, x.length ~/ 2);
      expect(() => readAll(XZDecoder().decodeLazy(InputMemoryStream(cut))),
          throwsA(isA<ArchiveException>()));

      expect(
          () => readAll(
              XZDecoder(maxDictionarySize: 0).decodeLazy(InputMemoryStream(x))),
          throwsA(isA<ArchiveLimitException>()));
    });
  });

  test('a view longer than the decoded data reads what there is', () {
    final data = sample(5000);
    final stream = InputDecodeStream(_ListDecoder(data));
    stream.skip(4000);
    final view = stream.readBytes(3000);
    stream.skip(0);
    expect(view.toUint8List(), equals(data.sublist(4000)));

    final late = InputDecodeStream(_ListDecoder(data));
    final past = late.subset(position: 6000, length: 100);
    expect(past.toUint8List(), isEmpty);

    // Once the window has slid along, a position past the end lies past its
    // buffer too
    final big = sample(300000);
    final slid = InputDecodeStream(_ListDecoder(big));
    while (!slid.isEOS) {
      slid.readBytes(1000).toUint8List();
    }
    expect(slid.subset(position: 400000, length: 10).toUint8List(), isEmpty);

    final output = OutputMemoryStream();
    output.writeStream(InputDecodeStream(_ListDecoder(data)).readBytes(8000));
    expect(output.getBytes(), equals(data));
  });

  test('TarDecoder reads a lazy stream without decoding ahead', () {
    final tar = TarEncoder().encodeBytes(Archive()
      ..add(ArchiveFile.bytes('a', Uint8List(1 << 20)))
      ..add(ArchiveFile.bytes('b', Uint8List(31 << 20))));
    final source = _ListDecoder(tar);
    final decodedAtFirst = <int>[];
    TarDecoder().decodeStream(InputDecodeStream(source),
        throwOnError: true, keepEntries: false, callback: (entry) {
      decodedAtFirst.add(source._pos);
      entry.writeContent(OutputMemoryStream());
    });
    expect(decodedAtFirst, hasLength(2));
    expect(decodedAtFirst.first, lessThan(4 << 20));
  });

  test('decodeLazy over a lazy input reads it a piece at a time', () {
    final xz = XZEncoder().encodeBytes(sample(1 << 20));
    final inner = _ListDecoder(xz);
    final lazy = XZDecoder().decodeLazy(InputDecodeStream(inner));
    expect(lazy.readByte(), sample(1)[0]);
    expect(inner._pos, lessThan(xz.length ~/ 2));
  });
}

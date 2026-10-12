import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

Uint8List _sample(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state =
        (state * 20077 + state * 16838 % 0x8000 * 0x10000 + 12345) % 0x80000000;
    bytes[i] = (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Stream<List<int>> _pieces(List<int> bytes, int size) async* {
  for (var at = 0; at < bytes.length; at += size) {
    yield bytes.sublist(
        at, at + size < bytes.length ? at + size : bytes.length);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final out = BytesBuilder();
  await for (final piece in stream) {
    out.add(piece);
  }
  return out.takeBytes();
}

class _Collect implements Sink<List<int>> {
  final bytes = BytesBuilder();
  var closed = false;

  @override
  void add(List<int> data) => bytes.add(data);

  @override
  void close() => closed = true;
}

List<ArchiveFile> _entries() => [
      ArchiveFile.string('readme.txt', 'the first entry'),
      ArchiveFile.bytes('dir/binary.dat', _sample(70000, 3)),
      ArchiveFile.bytes('${'long/' * 30}name.dat', _sample(700, 5)),
      ArchiveFile.bytes('empty.dat', Uint8List(0)),
    ]..forEach((entry) => entry.lastModTime = 1700000000);

void main() {
  final data = _sample(300000, 7);

  group('Deflate encoder parameters', () {
    test('invalid level or window throws ArgumentError', () {
      for (final (level, windowBits) in [(-1, 15), (10, 15), (6, 7), (6, 16)]) {
        expect(() => Deflate([1, 2, 3], level: level, windowBits: windowBits),
            throwsArgumentError);
        expect(
            () => Deflate.stream(InputMemoryStream([1, 2, 3]),
                level: level, windowBits: windowBits),
            throwsArgumentError);
        for (final encoder in [
          const GZipEncoderWeb(),
          const ZLibEncoderWeb()
        ]) {
          expect(
              () => encoder
                  .encodeBytes([1, 2, 3], level: level, windowBits: windowBits),
              throwsArgumentError);
          expect(
              () => encoder.encodeStream(
                  InputMemoryStream([1, 2, 3]), OutputMemoryStream(),
                  level: level, windowBits: windowBits),
              throwsArgumentError);
        }
      }
    });

    test('zlib encodeBytes and encodeStream write requested window size', () {
      final source = Uint8List.fromList(List.generate(20000, (i) => i % 511));
      for (final windowBits in [8, 9, 10, 11, 12, 13, 14, 15]) {
        final encoded =
            const ZLibEncoder().encodeBytes(source, windowBits: windowBits);
        final output = OutputMemoryStream();
        const ZLibEncoder().encodeStream(InputMemoryStream(source), output,
            windowBits: windowBits);
        expect(encoded, output.getBytes(), reason: 'windowBits $windowBits');
        expect(encoded[0] >> 4, (windowBits == 8 ? 9 : windowBits) - 8,
            reason: 'windowBits $windowBits');
        expect(ZLibDecoder().decodeBytes(encoded, verify: true), source);
        final web =
            const ZLibEncoderWeb().encodeBytes(source, windowBits: windowBits);
        expect(web[0] >> 4, (windowBits == 8 ? 9 : windowBits) - 8,
            reason: 'web windowBits $windowBits');
        expect(ZLibDecoder().decodeBytes(web, verify: true), source);
        expect(
            ZLibDecoder().decodeBytes(
                Deflate(source, windowBits: windowBits).getBytes(),
                raw: true,
                verify: true),
            source);
        expect(
            GZipDecoder().decodeBytes(
                const GZipEncoderWeb()
                    .encodeBytes(source, windowBits: windowBits),
                verify: true),
            source);
      }
    });
  });

  group('gzip verify on web', () {
    test('web decoders with verify reject malformed deflate', () {
      final header = Uint8List.fromList(ZLibEncoder().encodeBytes([1, 2, 3]));
      header[0] = 0x79;
      header[1] = (31 - ((header[0] << 8) % 31)) % 31;
      final source = Uint8List.fromList(List.generate(16384, (i) => i & 255));
      final table = Uint8List.fromList(ZLibEncoder().encodeBytes(source));
      table[8] ^= 0xff;
      for (final bad in [
        header,
        Uint8List.fromList([0x78, 0x9c, 0x03, 0xff, 0, 0, 0, 1]),
        table,
      ]) {
        expect(
            () => ZLibDecoder()
                .decodeBytes(bad, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        expect(
            () => ZLibDecoder().decodeStream(
                InputMemoryStream(bad), OutputMemoryStream(),
                verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      }
      final badGzip = Uint8List.fromList([
        0x1f,
        0x8b,
        8,
        0,
        0,
        0,
        0,
        0,
        0,
        0x13,
        0x03,
        0xff,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      ]);
      expect(
          () => GZipDecoder()
              .decodeBytes(badGzip, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          () => GZipDecoder().decodeStream(
              InputMemoryStream(badGzip), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test(
        'verify of 2 members works with write-only output that already has bytes',
        () {
      final encoded = GZipEncoder().encodeBytes(data);
      final collected = _Collect();
      final output = SinkOutputStream(collected)..writeBytes([1, 2, 3]);
      expect(
          GZipDecoder().decodeStream(
              InputMemoryStream([...encoded, ...encoded]), output,
              verify: true),
          isTrue);
      expect(collected.bytes.takeBytes(), [1, 2, 3, ...data, ...data]);
    });

    test('verify with throwOnError throws on wrong CRC of last member', () {
      final encoded = GZipEncoder().encodeBytes(data);
      final damaged = [...encoded, ...encoded];
      damaged[damaged.length - 8] ^= 1;
      expect(
          () => GZipDecoder()
              .decodeBytes(damaged, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('zstd converters on web', () {
    test('codec encodes and decodes whole buffer back', () {
      expect(zstdCodec.decode(zstdCodec.encode(data)), data);
    });

    for (final size in [1, 4096, 65536]) {
      test('stream in pieces of $size encodes and decodes back', () async {
        final input = size == 1 ? data.sublist(0, 20000) : data;
        final compressed =
            await _collect(_pieces(input, size).transform(zstdCodec.encoder));
        expect(ZstdDecoder().decodeBytes(compressed), input);
        final back = await _collect(
            _pieces(compressed, size).transform(zstdCodec.decoder));
        expect(back, input);
      });
    }

    test('decoder reads output of encodeBytes', () async {
      final compressed = ZstdEncoder().encodeBytes(data);
      expect(
          await _collect(
              _pieces(compressed, 1000).transform(zstdCodec.decoder)),
          data);
    });
  });

  group('bzip2 converters on web', () {
    test('codec encodes and decodes whole buffer back', () {
      expect(bzip2Codec.decode(bzip2Codec.encode(data)), data);
    });

    for (final size in [1, 4096, 65536]) {
      test('stream in pieces of $size encodes and decodes back', () async {
        final input = size == 1 ? data.sublist(0, 20000) : data;
        final compressed =
            await _collect(_pieces(input, size).transform(bzip2Codec.encoder));
        expect(BZip2Decoder().decodeBytes(compressed, verify: true), input);
        final back = await _collect(
            _pieces(compressed, size).transform(bzip2Codec.decoder));
        expect(back, input);
      });
    }

    test('decoder reads output of encodeBytes', () async {
      final compressed = BZip2Encoder().encodeBytes(data, blockSize100k: 1);
      expect(
          await _collect(
              _pieces(compressed, 1000).transform(bzip2Codec.decoder)),
          data);
    });
  });

  group('tar converters on web', () {
    test('TarDecoder reads TarChunkedEncoder output', () {
      final sink = _Collect();
      final encoder = TarChunkedEncoder(sink);
      for (final entry in _entries()) {
        encoder.add(entry);
      }
      encoder.close();
      expect(sink.closed, isTrue);
      final archive = TarDecoder().decodeBytes(sink.bytes.takeBytes());
      final want = _entries();
      expect(archive.files.map((f) => f.name), want.map((e) => e.name));
      for (var i = 0; i < want.length; i++) {
        expect(archive.files[i].content, want[i].content);
      }
    });

    test('tarCodec encodes and decodes back through streams', () async {
      final bytes = await _collect(Stream<ArchiveFile>.fromIterable(_entries())
          .transform(tarCodec.encoder));
      final got = <String, List<int>>{};
      await for (final entry
          in _pieces(bytes, 777).transform(tarCodec.decoder)) {
        final content = <int>[];
        await for (final part in entry.content) {
          content.addAll(part);
        }
        got[entry.name] = content;
      }
      final want = _entries();
      expect(got.keys, want.map((e) => e.name));
      for (final entry in want) {
        expect(got[entry.name], entry.content);
      }
    });
  });

  group('zip converters on web', () {
    for (final streamed in [true, false]) {
      test('ZipDecoder reads ZipChunkedEncoder output, streamed: $streamed',
          () {
        final sink = _Collect();
        final encoder = ZipChunkedEncoder(sink, streamed: streamed);
        for (final entry in _entries()) {
          encoder.add(entry);
        }
        encoder.close();
        expect(sink.closed, isTrue);
        final archive =
            ZipDecoder().decodeBytes(sink.bytes.takeBytes(), verify: true);
        final want = _entries();
        expect(archive.files.map((f) => f.name), want.map((e) => e.name));
        for (var i = 0; i < want.length; i++) {
          expect(archive.files[i].content, want[i].content);
        }
      });
    }

    test('ZipDecoder reads zipCodec encoder output', () async {
      final bytes = await _collect(Stream<ArchiveFile>.fromIterable(_entries())
          .transform(zipCodec.encoder));
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final want = _entries();
      expect(archive.files.map((f) => f.name), want.map((e) => e.name));
      for (var i = 0; i < want.length; i++) {
        expect(archive.files[i].content, want[i].content);
      }
    });
  });

  group('CodecsRecognizer on web', () {
    final small = _sample(5000, 11);
    final archive = Archive()..add(ArchiveFile.bytes('a.dat', small));
    final formats = <ArchiveFormat, Uint8List>{
      ArchiveFormat.gzip: GZipEncoder().encodeBytes(small),
      ArchiveFormat.bzip2: BZip2Encoder().encodeBytes(small),
      ArchiveFormat.xz: XZEncoder().encodeBytes(small),
      ArchiveFormat.zstd: ZstdEncoder().encodeBytes(small),
      ArchiveFormat.zip: ZipEncoder().encodeBytes(archive),
      ArchiveFormat.tar: TarEncoder().encodeBytes(archive),
    };

    for (final entry in formats.entries) {
      test('recognizes ${entry.key.name}', () {
        expect(CodecsRecognizer.recognize(entry.value), entry.key);
      });
    }

    test('recognizes zlib only with withZLib', () {
      final zlib = ZLibEncoder().encodeBytes(small);
      expect(CodecsRecognizer.isZLib(zlib), isTrue);
      expect(
          CodecsRecognizer.recognize(zlib, withZLib: true), ArchiveFormat.zlib);
    });

    test('plain text is unknown', () {
      expect(CodecsRecognizer.recognize(utf8.encode('just some text')),
          ArchiveFormat.unknown);
    });
  });
}

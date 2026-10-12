import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

const _isWeb = bool.fromEnvironment('dart.library.js_interop');

typedef _DecodeWithFlags = bool Function(InputStream, OutputStream,
    {bool verify, bool throwOnError});

Uint8List _data() {
  // Above the 1 MiB pieces the zstd window hands out, so it reports twice
  final out = Uint8List(5 << 19);
  var seed = 1;
  for (var i = 0; i < out.length; ++i) {
    seed ^= (seed << 13) & 0xffffffff;
    seed ^= seed >> 17;
    seed ^= (seed << 5) & 0xffffffff;
    out[i] = 0x61 + (seed >> 16) % 16;
  }
  return out;
}

void main() {
  final data = _data();

  final decoders =
      <String, (List<int>, bool Function(InputStream, OutputStream))>{
    'gzip': (
      GZipEncoder().encodeBytes(data),
      (i, o) => const GZipDecoder().decodeStream(i, o)
    ),
    'gzip web': (
      GZipEncoder().encodeBytes(data),
      (i, o) => const GZipDecoderWeb().decodeStream(i, o)
    ),
    'zlib': (
      ZLibEncoder().encodeBytes(data),
      (i, o) => const ZLibDecoder().decodeStream(i, o)
    ),
    'zstd': (
      ZstdEncoder().encodeBytes(data),
      (i, o) => ZstdDecoder().decodeStream(i, o)
    ),
    'bzip2': (
      BZip2Encoder().encodeBytes(data),
      (i, o) => BZip2Decoder().decodeStream(i, o)
    ),
    'xz': (
      XZEncoder().encodeBytes(data),
      (i, o) => XZDecoder().decodeStream(i, o)
    ),
  };

  group('ProgressOutputStream', () {
    final callbackData = Uint8List.fromList(List.generate(64, (i) => i));
    final callbackDecoders = <String, (List<int>, _DecodeWithFlags)>{
      'gzip': (
        GZipEncoder().encodeBytes(callbackData),
        const GZipDecoder().decodeStream
      ),
      'gzip web': (
        GZipEncoder().encodeBytes(callbackData),
        const GZipDecoderWeb().decodeStream
      ),
      'zlib': (
        ZLibEncoder().encodeBytes(callbackData),
        const ZLibDecoder().decodeStream
      ),
      'zlib web': (
        ZLibEncoder().encodeBytes(callbackData),
        const ZLibDecoderWeb().decodeStream
      ),
      'bzip2': (
        BZip2Encoder().encodeBytes(callbackData),
        BZip2Decoder().decodeStream
      ),
      'xz': (XZEncoder().encodeBytes(callbackData), XZDecoder().decodeStream),
      'zstd': (
        ZstdEncoder().encodeBytes(callbackData),
        ZstdDecoder().decodeStream
      ),
    };
    for (final MapEntry(key: name, value: (packed, decode))
        in callbackDecoders.entries) {
      for (final flags in ['default', 'throwOnError', 'verify']) {
        test('$name finishes when onProgress throws, with $flags', () {
          final failure = StateError('progress failed');
          final errors = <Object>[];
          final output = OutputMemoryStream();
          late bool ok;
          runZonedGuarded(() {
            ok = decode(InputMemoryStream(packed),
                ProgressOutputStream(output, (_) => throw failure, interval: 1),
                verify: flags == 'verify',
                throwOnError: flags == 'throwOnError');
          }, (error, _) => errors.add(error));
          expect(ok, isTrue);
          expect(output.getBytes(), callbackData);
          expect(errors, isNotEmpty);
          expect(errors, everyElement(same(failure)));
        });
      }
    }

    for (final synchronous in [false, true]) {
      test('closes output when last onProgress throws, sync: $synchronous',
          () async {
        final output = _CloseTrackingOutput();
        final failure = StateError('progress failed');
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final out = ProgressOutputStream(output, (_) => throw failure);
          out.writeBytes([1, 2, 3]);
          if (synchronous) {
            out.closeSync();
          } else {
            await out.close();
          }
        }, (error, _) => errors.add(error));
        expect(errors, [same(failure)]);
        expect(output.closed, isTrue);
        expect(output.getBytes(), [1, 2, 3]);
      });
    }

    for (final MapEntry(key: name, value: (packed, decode))
        in decoders.entries) {
      test('$name reports progress during decode', () {
        final input = InputMemoryStream(packed);
        final total = input.length;
        final seen = <int>[];
        final fractions = <double>[];
        final out = ProgressOutputStream(OutputMemoryStream(), (written) {
          seen.add(written);
          fractions.add(input.position / total);
        });
        expect(decode(input, out), isTrue);
        out.closeSync();
        expect(out.getBytes(), equals(data));
        expect(out.written, data.length);
        expect(seen.length, greaterThan(1));
        expect(seen.last, data.length);
        for (var i = 1; i < seen.length; ++i) {
          expect(seen[i], greaterThan(seen[i - 1]));
          expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
        }
      },
          skip: name == 'zlib' && _isWeb
              ? 'the web zlib decoder inflates a member whole before writing'
              : false);
    }

    test('passes every write to output', () {
      final seen = <int>[];
      final out =
          ProgressOutputStream(OutputMemoryStream(), seen.add, interval: 1);
      out.byteOrder = ByteOrder.bigEndian;
      out
        ..writeByte(1)
        ..writeUint16(0x0203)
        ..writeUint32(0x04050607)
        ..writeUint64(0x0c0d0e0f)
        ..writeBytes([1, 2, 3, 4], length: 2)
        ..writeRange(Uint8List.fromList([9, 8, 7, 6]), 1, 3)
        ..writeBackReference(2, 5)
        ..writeStream(InputMemoryStream(Uint8List.fromList([5, 5, 5])));
      expect(out.output.byteOrder, ByteOrder.bigEndian);
      expect(out.getBytes(), [
        1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 12, 13, 14, 15, //
        1, 2, 8, 7, 8, 7, 8, 7, 8, 5, 5, 5,
      ]);
      expect(out.length, 27);
      expect(seen, [1, 3, 7, 15, 17, 19, 24, 27]);
    });

    test('reports remainder once on flush and close', () {
      final seen = <int>[];
      final out =
          ProgressOutputStream(OutputMemoryStream(), seen.add, interval: 100);
      out.writeBytes(Uint8List(250));
      expect(seen, [250]);
      out.writeBytes(Uint8List(30));
      out.flush();
      out.closeSync();
      expect(seen, [250, 280]);
    });

    test('writeStream reports progress during copy', () {
      final seen = <int>[];
      final out = ProgressOutputStream(OutputMemoryStream(), seen.add);
      out.writeStream(InputMemoryStream(data));
      out.closeSync();
      expect(out.getBytes(), equals(data));
      expect(seen.length, greaterThan(1));
      expect(seen.last, data.length);
    });

    final stored = <String, ArchiveFile Function()>{
      'tar': () => TarDecoder()
          .decodeBytes(TarEncoder()
              .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', data))))
          .single,
      'stored zip': () => ZipDecoder()
          .decodeBytes(ZipEncoder().encodeBytes(Archive()
            ..add(ArchiveFile.bytes('a.bin', data)
              ..compression = CompressionType.none)))
          .single,
    };
    for (final MapEntry(key: name, value: entry) in stored.entries) {
      test('$name entry reports progress during write', () {
        final seen = <int>[];
        final out = ProgressOutputStream(OutputMemoryStream(), seen.add);
        entry().writeContent(out);
        out.closeSync();
        expect(out.getBytes(), equals(data));
        expect(seen.length, greaterThan(1));
        expect(seen.last, data.length);
      });
    }
  });
}

class _CloseTrackingOutput extends OutputMemoryStream {
  bool closed = false;

  @override
  Future<void> close() async {
    await Future<void>.value();
    closeSync();
  }

  @override
  void closeSync() {
    closed = true;
  }
}

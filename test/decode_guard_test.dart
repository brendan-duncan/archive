import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/decode_guard.dart';
import 'package:test/test.dart';

typedef _Decode = bool Function(InputStream, OutputStream,
    {bool verify, bool throwOnError});

void main() {
  bool fails() => false;
  bool checksum() => throw ArchiveChecksumException('checksum');
  bool damage() => throw ArchiveException('damage');
  bool range() => throw RangeError('range');

  final plain =
      allOf(isA<ArchiveException>(), isNot(isA<ArchiveChecksumException>()));

  test('without flags guardDecode returns false and does not throw', () {
    for (final decode in [fails, checksum, damage, range]) {
      expect(guardDecode('x', false, false, decode), isFalse);
    }
    expect(guardDecode('x', false, false, () => true), isTrue);
  });

  test('throwOnError throws ArchiveException, never ArchiveChecksumException',
      () {
    for (final decode in [fails, checksum, damage, range]) {
      expect(() => guardDecode('x', false, true, decode), throwsA(plain));
    }
  });

  test('verify without throwOnError returns false and does not throw', () {
    for (final decode in [fails, checksum, damage, range]) {
      expect(guardDecode('x', true, false, decode), isFalse);
    }
    expect(guardDecode('x', true, false, () => true), isTrue);
  });

  test(
      'verify with throwOnError throws ArchiveChecksumException only for '
      'checksum errors', () {
    expect(() => guardDecode('x', true, true, checksum),
        throwsA(isA<ArchiveChecksumException>()));
    for (final decode in [fails, damage, range]) {
      expect(() => guardDecode('x', true, true, decode), throwsA(plain));
    }
  });

  test('failed null check counts as damaged data', () {
    bool nullCheck() => throw TypeError();
    expect(guardDecode('x', false, false, nullCheck), isFalse);
    expect(() => guardDecode('x', false, true, nullCheck), throwsA(plain));
    expect(guardDecode('x', true, false, nullCheck), isFalse);
  });

  test('throwIfStrict follows guardDecode rules', () {
    String outcome(void Function() f) {
      try {
        f();
        return 'none';
      } catch (error) {
        return '${error.runtimeType} ${(error as ArchiveException).message}';
      }
    }

    for (final error in [
      ArchiveException('damage'),
      ArchiveChecksumException('checksum'),
      ArchivePasswordException('password'),
    ]) {
      for (final (verify, throwOnError) in [
        (false, false),
        (false, true),
        (true, false),
        (true, true)
      ]) {
        expect(
            outcome(() => throwIfStrict(error, verify, throwOnError)),
            outcome(() =>
                guardDecode('x', verify, throwOnError, () => throw error)),
            reason: '$error, verify $verify, throwOnError $throwOnError');
      }
    }
  });

  group('output stream error', () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i * 7 % 251));
    final decoders = <String, (List<int>, _Decode)>{
      'gzip': (
        GZipEncoder().encodeBytes(data),
        const GZipDecoder().decodeStream
      ),
      'gzip web': (
        GZipEncoder().encodeBytes(data),
        const GZipDecoderWeb().decodeStream
      ),
      'zlib': (
        ZLibEncoder().encodeBytes(data),
        const ZLibDecoder().decodeStream
      ),
      'zlib web': (
        ZLibEncoder().encodeBytes(data),
        const ZLibDecoderWeb().decodeStream
      ),
      'bzip2': (BZip2Encoder().encodeBytes(data), BZip2Decoder().decodeStream),
      'xz': (XZEncoder().encodeBytes(data), XZDecoder().decodeStream),
      'zstd': (ZstdEncoder().encodeBytes(data), ZstdDecoder().decodeStream),
    };
    final zip = ZipEncoder()
        .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', data)));

    for (final (verify, throwOnError) in [
      (false, false),
      (false, true),
      (true, false)
    ]) {
      final flags = 'verify $verify, throwOnError $throwOnError';
      for (final MapEntry(key: name, value: (packed, decode))
          in decoders.entries) {
        test('$name rethrows it unchanged with $flags', () {
          final failure = _DiskFull();
          expect(
              () => decode(InputMemoryStream(packed), _FullOutput(failure),
                  verify: verify, throwOnError: throwOnError),
              throwsA(same(failure)));
        });
      }

      test('zip entry rethrows it unchanged with $flags', () {
        final failure = _DiskFull();
        final entry = ZipDecoder()
            .decodeBytes(zip, verify: verify, throwOnError: throwOnError)
            .files
            .single;
        expect(() => entry.writeContent(_FullOutput(failure)),
            throwsA(same(failure)));
      });

      test('zip LZMA entry rethrows it unchanged with $flags', () {
        final failure = _DiskFull();
        final entry = ZipDecoder()
            .decodeBytes(File('test/_data/zip/lzma_near.zip').readAsBytesSync(),
                verify: verify, throwOnError: throwOnError)
            .files
            .firstWhere((file) => file.isFile);
        expect(() => entry.writeContent(_FullOutput(failure)),
            throwsA(same(failure)));
      }, testOn: 'vm');
    }

    test('Inflate.addBytes rethrows it unchanged', () {
      final failure = _DiskFull();
      final inflate = Inflate.stream(null, output: _FullOutput(failure));
      expect(() => inflate.addBytes(Deflate(data).getBytes()),
          throwsA(same(failure)));
    });
  });
}

class _DiskFull implements Exception {}

class _FullOutput extends OutputStream {
  final Object failure;

  _FullOutput(this.failure) : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => 0;

  @override
  void clear() {}

  @override
  void flush() {}

  @override
  void writeByte(int value) => throw failure;

  @override
  void writeBytes(List<int> bytes, {int? length}) => throw failure;

  @override
  void writeStream(InputStream stream) => throw failure;

  @override
  Uint8List subset(int start, [int? end]) => Uint8List(0);
}

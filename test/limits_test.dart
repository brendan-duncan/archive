import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// A small input can decode to far more than it is: deflate reaches about
// 1000:1 and zstd 32000:1. These check the limits a caller can set on it.

final data = Uint8List(100000);

void expectLimit(Uint8List Function(int max) decode) {
  expect(decode(data.length), equals(data));
  expect(() => decode(data.length - 1), throwsA(isA<ArchiveException>()));
}

void expectStreamLimit(bool Function(OutputStream output, int max) decode) {
  final output = OutputMemoryStream();
  expect(decode(output, data.length), isTrue);
  expect(output.getBytes(), equals(data));
  expect(() => decode(OutputMemoryStream(), data.length - 1),
      throwsA(isA<ArchiveException>()));
}

// Rewrites the uncompressed size that the local and central headers of the
// only entry in [zip] give, leaving its data alone.
Uint8List withDeclaredSize(Uint8List zip, int size) {
  final bytes = Uint8List.fromList(zip);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i + 4 <= bytes.length; i++) {
    final signature = view.getUint32(i, Endian.little);
    if (signature == 0x04034b50) {
      view.setUint32(i + 22, size, Endian.little);
    } else if (signature == 0x02014b50) {
      view.setUint32(i + 24, size, Endian.little);
    }
  }
  return bytes;
}

void main() {
  group('maxOutputSize', () {
    test('gzip', () {
      final gz = GZipEncoder().encodeBytes(data);
      expectLimit((max) => GZipDecoder().decodeBytes(gz, maxOutputSize: max));
      expectStreamLimit((output, max) => GZipDecoder()
          .decodeStream(InputMemoryStream(gz), output, maxOutputSize: max));
    });

    test('zlib', () {
      final z = ZLibEncoder().encodeBytes(data);
      expectLimit((max) => ZLibDecoder().decodeBytes(z, maxOutputSize: max));
      expectStreamLimit((output, max) => ZLibDecoder()
          .decodeStream(InputMemoryStream(z), output, maxOutputSize: max));
    });

    test('bzip2', () {
      final bz = BZip2Encoder().encodeBytes(data);
      expectLimit((max) => BZip2Decoder().decodeBytes(bz, maxOutputSize: max));
      expectStreamLimit((output, max) => BZip2Decoder()
          .decodeStream(InputMemoryStream(bz), output, maxOutputSize: max));
    });

    test('zstd', () {
      final zst = ZstdEncoder().encodeBytes(data);
      expectLimit((max) => ZstdDecoder().decodeBytes(zst, maxOutputSize: max));
      expectStreamLimit((output, max) => ZstdDecoder()
          .decodeStream(InputMemoryStream(zst), output, maxOutputSize: max));
    });

    test('rejects a negative limit', () {
      expect(() => ZstdDecoder().decodeBytes(Uint8List(0), maxOutputSize: -1),
          throwsArgumentError);
    });
  });

  group('zip entries', () {
    final archive = Archive()..add(ArchiveFile.bytes('zeros', data));

    for (final level in [0, 6]) {
      test('decode no further than their declared size, level $level', () {
        final zip = ZipEncoder().encodeBytes(archive, level: level);
        final honest = ZipDecoder().decodeBytes(zip);
        expect(honest[0].readBytes(), equals(data));

        final lying = ZipDecoder().decodeBytes(withDeclaredSize(zip, 1000));
        expect(lying[0].size, equals(1000));
        expect(() => lying[0].readBytes(), throwsA(isA<ArchiveException>()));
        expect(() => lying[0].writeContent(OutputMemoryStream()),
            throwsA(isA<ArchiveException>()));
      });
    }
  });

  group('extract maxSize', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('limits'));
    tearDown(() => dir.deleteSync(recursive: true));

    final archive = Archive()
      ..add(ArchiveFile.bytes('a', Uint8List(1000)))
      ..add(ArchiveFile.bytes('b', Uint8List(1000)));

    for (final ext in ['.tar.gz', '.zip']) {
      test(ext, () async {
        final bytes = ext == '.zip'
            ? ZipEncoder().encodeBytes(archive)
            : GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
        final path = p.join(dir.path, 'in$ext');
        File(path).writeAsBytesSync(bytes);

        await extractFileToDisk(path, p.join(dir.path, 'ok'), maxSize: 2000);
        expect(File(p.join(dir.path, 'ok', 'b')).lengthSync(), equals(1000));

        await expectLater(
            extractFileToDisk(path, p.join(dir.path, 'over'), maxSize: 1999),
            throwsA(isA<ArchiveException>()));
        expect(File(p.join(dir.path, 'over', 'b')).existsSync(), isFalse);
      });
    }

    test('extractArchiveToDisk', () async {
      await extractArchiveToDisk(archive, p.join(dir.path, 'ok'),
          maxSize: 2000);
      await expectLater(
          extractArchiveToDisk(archive, p.join(dir.path, 'over'),
              maxSize: 1999),
          throwsA(isA<ArchiveException>()));
      expect(
          () => extractArchiveToDiskSync(archive, p.join(dir.path, 'sync'),
              maxSize: 1999),
          throwsA(isA<ArchiveException>()));
    });
  });
}

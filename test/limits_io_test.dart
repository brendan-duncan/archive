@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
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
            throwsA(isA<ArchiveLimitException>()));
        expect(File(p.join(dir.path, 'over', 'b')).existsSync(), isFalse);
      });
    }

    test('extractArchiveToDisk', () async {
      await extractArchiveToDisk(archive, p.join(dir.path, 'ok'),
          maxSize: 2000);
      await expectLater(
          extractArchiveToDisk(archive, p.join(dir.path, 'over'),
              maxSize: 1999),
          throwsA(isA<ArchiveLimitException>()));
      expect(
          () => extractArchiveToDiskSync(archive, p.join(dir.path, 'sync'),
              maxSize: 1999),
          throwsA(isA<ArchiveLimitException>()));
    });
  });
}

@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final callback in ['filter', 'progress']) {
    test('$callback filesystem failure preserves completed ZIP entries',
        () async {
      final root = Directory.systemTemp.createTempSync('archive-zip-callback-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = Directory(p.join(root.path, 'source'))..createSync();
      File(p.join(source.path, 'a.txt')).writeAsStringSync('data');
      File(p.join(source.path, 'b.txt')).writeAsStringSync('data');
      final out = p.join(root.path, 'partial.zip');
      final failure = FileSystemException('callback failed');
      var calls = 0;
      await expectLater(
        ZipFileEncoder().zipDirectory(source,
            filename: out,
            filter: callback == 'filter'
                ? (entry, progress) {
                    if (++calls == 2) throw failure;
                    return ZipFileOperation.include;
                  }
                : null,
            onProgress: callback == 'progress' ? (_) => throw failure : null),
        throwsA(same(failure)),
      );
      expect(File(out).existsSync(), isTrue);
      final zip =
          ZipDecoder().decodeBytes(File(out).readAsBytesSync(), verify: true);
      expect(zip.length, 1);
      expect(zip.first.readBytes(), 'data'.codeUnits);
    });
  }

  test('failed ZIP directory creation deletes a partially written archive',
      () async {
    final root = Directory.systemTemp.createTempSync('archive-zip-failure-');
    addTearDown(() => root.deleteSync(recursive: true));
    final input = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(input.path, 'a.txt')).writeAsStringSync('data');
    File(p.join(input.path, 'b.txt')).writeAsStringSync('data');
    final out = p.join(root.path, 'archive.zip');

    await expectLater(
      ZipFileEncoder().zipDirectory(input, filename: out,
          filter: (entry, progress) {
        if (entry is File) {
          // Force a real source I/O error after ZIP output was created.
          entry.deleteSync();
        }
        return ZipFileOperation.include;
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(out).existsSync(), isFalse);
  });

  test('a source error that is not a FileSystemException deletes the ZIP',
      () async {
    final root = Directory.systemTemp.createTempSync('archive-zip-name-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(source.path, 'a.txt')).writeAsStringSync('data');
    final out = p.join(root.path, 'archive.zip');
    final encoder = ZipFileEncoder();
    await expectLater(
      encoder.zipDirectory(source, filename: out, level: 70000),
      throwsA(anything),
    );
    expect(File(out).existsSync(), isFalse);
  });

  test('ZIP cancellation still completes as a valid partial archive', () async {
    final root = Directory.systemTemp.createTempSync('archive-zip-cancel-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(source.path, 'a.txt')).writeAsStringSync('a');
    final out = p.join(root.path, 'cancelled.zip');

    await ZipFileEncoder().zipDirectory(source,
        filename: out, filter: (entry, progress) => ZipFileOperation.cancel);
    expect(File(out).existsSync(), isTrue);
    expect(ZipDecoder().decodeBytes(File(out).readAsBytesSync()), isEmpty);
  });

  test('successful ZIP directory still preserves all entries', () async {
    final root = Directory.systemTemp.createTempSync('archive-zip-success-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = Directory(p.join(root.path, 'source'))..createSync();
    File(p.join(source.path, 'a.txt')).writeAsStringSync('hello');
    final out = p.join(root.path, 'complete.zip');
    await ZipFileEncoder().zipDirectory(source, filename: out);
    expect(
        ZipDecoder()
            .decodeBytes(File(out).readAsBytesSync())
            .findFile('a.txt')
            ?.readBytes(),
        'hello'.codeUnits);
  });
}

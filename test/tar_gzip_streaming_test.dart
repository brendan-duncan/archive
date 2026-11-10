@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final compression in [TarFileEncoder.gzip, TarFileEncoder.zstd]) {
    test('compressed output inside the source is not archived: $compression',
        () async {
      final base = Directory.systemTemp.createTempSync('archive-self-output-');
      addTearDown(() => base.deleteSync(recursive: true));
      final source = Directory(p.join(base.path, 'source'))..createSync();
      File(p.join(source.path, 'keep.txt')).writeAsStringSync('keep');
      final output = p.join(source.path, 'result.archive');
      final observed = <String>[];
      final progress = <double>[];
      await TarFileEncoder().tarDirectory(source,
          compression: compression, filename: output, filter: (file, fraction) {
        observed.add(p.basename(file.path));
        progress.add(fraction);
        return ZipFileOperation.include;
      });
      final compressed = File(output).readAsBytesSync();
      final decoded = compression == TarFileEncoder.gzip
          ? GZipDecoder().decodeBytes(compressed, verify: true)
          : ZstdDecoder().decodeBytes(compressed, verify: true);
      final tar = TarDecoder().decodeBytes(decoded, verify: true);
      expect(tar.files.map((file) => file.name), ['source/keep.txt']);
      expect(observed, ['keep.txt']);
      expect(progress, [1.0]);
    });
  }

  test('streamed tar.zst roundtrips a multi-megabyte file with checksum',
      () async {
    final base = Directory.systemTemp.createTempSync('archive-tzst-stream-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    Directory(p.join(source.path, 'nested')).createSync();
    final payload = Uint8List(3 * 1024 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (i * 37 + i ~/ 701) & 0xff;
    }
    File(p.join(source.path, 'nested', 'large.bin')).writeAsBytesSync(payload);
    final output = p.join(base.path, 'output.tar.zst');

    await TarFileEncoder().tarDirectory(
      source,
      compression: TarFileEncoder.zstd,
      filename: output,
      level: 3,
    );

    final decoded = ZstdDecoder().decodeBytes(
      File(output).readAsBytesSync(),
      verify: true,
      throwOnError: true,
    );
    final tar = TarDecoder().decodeBytes(decoded, verify: true);
    expect(tar.findFile('source/${p.join('nested', 'large.bin')}')?.readBytes(),
        payload);
  });

  test('streamed tar.zst preserves filters and removes failed output',
      () async {
    final base = Directory.systemTemp.createTempSync('archive-tzst-filter-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    File(p.join(source.path, 'keep.txt')).writeAsStringSync('keep');
    File(p.join(source.path, 'skip.txt')).writeAsStringSync('skip');
    final output = p.join(base.path, 'filtered.tar.zst');
    await TarFileEncoder().tarDirectory(
      source,
      compression: TarFileEncoder.zstd,
      filename: output,
      filter: (entry, progress) => p.basename(entry.path) == 'skip.txt'
          ? ZipFileOperation.skip
          : ZipFileOperation.include,
    );
    final decoded =
        ZstdDecoder().decodeBytes(File(output).readAsBytesSync(), verify: true);
    final archive = TarDecoder().decodeBytes(decoded);
    expect(archive.findFile('source/keep.txt')?.readBytes(), 'keep'.codeUnits);
    expect(archive.findFile('source/skip.txt'), isNull);

    final invalid = p.join(base.path, 'invalid.tar.zst');
    await expectLater(
      TarFileEncoder().tarDirectory(
        source,
        compression: TarFileEncoder.zstd,
        filename: invalid,
        filter: (entry, progress) => throw StateError('abort'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(File(invalid).existsSync(), isFalse);
  });

  test('streamed tar.gz roundtrips nested files and a large asset', () async {
    final base = Directory.systemTemp.createTempSync('archive-tgz-stream-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    Directory(p.join(source.path, 'nested')).createSync();

    final bytes = Uint8List(8 * 1024 * 1024);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 37 + i ~/ 1003) & 0xff;
    }
    File(p.join(source.path, 'large.bin')).writeAsBytesSync(bytes);
    File(p.join(source.path, 'nested', 'hebrew.txt')).writeAsStringSync('שלום');

    final out = p.join(base.path, 'books.tar.gz');
    await TarFileEncoder()
        .tarDirectory(source, compression: TarFileEncoder.gzip, filename: out);

    final archive = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(File(out).readAsBytesSync(), verify: true),
      verify: true,
    );
    expect(archive.findFile('source/large.bin')?.readBytes(), bytes);
    expect(
        archive
            .findFile('source/${p.join('nested', 'hebrew.txt')}')
            ?.readBytes(),
        File(p.join(source.path, 'nested', 'hebrew.txt')).readAsBytesSync());
  });

  test('streamed tar.gz preserves filter semantics and compression level',
      () async {
    final base = Directory.systemTemp.createTempSync('archive-tgz-filter-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    File(p.join(source.path, 'keep.txt')).writeAsStringSync('keep');
    File(p.join(source.path, 'skip.txt')).writeAsStringSync('skip');
    final observed = <double>[];
    for (final level in [1, 6, 9]) {
      final out = p.join(base.path, 'filtered-$level.tgz');
      await TarFileEncoder().tarDirectory(source,
          compression: TarFileEncoder.gzip,
          level: level,
          filename: out, filter: (file, progress) {
        observed.add(progress);
        return p.basename(file.path) == 'skip.txt'
            ? ZipFileOperation.skip
            : ZipFileOperation.include;
      });
      final archive = TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(File(out).readAsBytesSync(), verify: true));
      expect(
          archive.findFile('source/keep.txt')?.readBytes(), 'keep'.codeUnits);
      expect(archive.findFile('source/skip.txt'), isNull);
    }
    expect(observed, isNotEmpty);
    expect(observed.last, 1.0);
  });

  test('invalid compression level does not leave a partial archive', () async {
    final base = Directory.systemTemp.createTempSync('archive-tgz-level-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    File(p.join(source.path, 'good.txt')).writeAsStringSync('good');
    final output = p.join(base.path, 'invalid.tar.gz');

    await expectLater(
        TarFileEncoder().tarDirectory(source,
            compression: TarFileEncoder.gzip, filename: output, level: 99),
        throwsA(anything));
    expect(File(output).existsSync(), isFalse);
  });

  test('compression errors remove partial archive', () async {
    final base = Directory.systemTemp.createTempSync('archive-tgz-failed-');
    addTearDown(() => base.deleteSync(recursive: true));
    final source = Directory(p.join(base.path, 'source'))..createSync();
    File(p.join(source.path, 'ok.txt')).writeAsStringSync('ok');
    final out = p.join(base.path, 'failed.tar.gz');
    await expectLater(
      TarFileEncoder().tarDirectory(source,
          compression: TarFileEncoder.gzip,
          filename: out,
          filter: (file, progress) => throw StateError('abort')),
      throwsA(isA<StateError>()),
    );
    expect(File(out).existsSync(), isFalse);
  });
}

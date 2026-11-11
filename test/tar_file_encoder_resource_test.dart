@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MetadataFailureFile implements File {
  final File source;
  final Object error;

  _MetadataFailureFile(this.source, this.error);

  @override
  String get path => source.path;

  @override
  Future<DateTime> lastModified() async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

int _openDescriptorsFor(String filePath) {
  final canonical = File(filePath).resolveSymbolicLinksSync();
  var count = 0;
  for (final descriptor
      in Directory('/proc/self/fd').listSync(followLinks: false)) {
    if (descriptor is! Link) continue;
    try {
      if (descriptor.targetSync() == canonical) count++;
    } on FileSystemException {
      // A descriptor can close while the directory is being listed.
    }
  }
  return count;
}

void main() {
  test('async TAR directory traversal keeps all files without a filter',
      () async {
    final dir = Directory.systemTemp.createTempSync('archive-tar-lazy-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = Directory(p.join(dir.path, 'source'))..createSync();
    Directory(p.join(source.path, 'sub')).createSync();
    File(p.join(source.path, 'a.txt')).writeAsStringSync('alpha');
    File(p.join(source.path, 'sub', 'b.txt')).writeAsStringSync('beta');

    final output = p.join(dir.path, 'all.tar');
    await TarFileEncoder().tarDirectory(source, filename: output);

    final archive = TarDecoder().decodeBytes(File(output).readAsBytesSync());
    expect(archive.findFile('source/a.txt')?.readBytes(), 'alpha'.codeUnits);
    expect(archive.findFile('source/${p.join('sub', 'b.txt')}')?.readBytes(),
        'beta'.codeUnits);
  });

  test('async TAR traversal retains filtering and accurate progress', () async {
    final dir = Directory.systemTemp.createTempSync('archive-tar-filter-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = Directory(p.join(dir.path, 'source'))..createSync();
    File(p.join(source.path, 'keep.txt')).writeAsStringSync('keep');
    File(p.join(source.path, 'skip.txt')).writeAsStringSync('skip');

    final progress = <double>[];
    final output = p.join(dir.path, 'filtered.tar');
    await TarFileEncoder().tarDirectory(source, filename: output,
        filter: (file, fraction) {
      progress.add(fraction);
      return p.basename(file.path) == 'skip.txt'
          ? ZipFileOperation.skip
          : ZipFileOperation.include;
    });

    final archive = TarDecoder().decodeBytes(File(output).readAsBytesSync());
    expect(archive.findFile('source/keep.txt')?.readBytes(), 'keep'.codeUnits);
    expect(archive.findFile('source/skip.txt'), isNull);
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
  });

  test('metadata failure closes the input handle and preserves the error',
      () async {
    final dir = Directory.systemTemp.createTempSync('archive-tar-resource-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = File(p.join(dir.path, 'input.txt'))
      ..writeAsStringSync('data');
    final output = File(p.join(dir.path, 'out.tar'));
    final encoder = TarFileEncoder()..create(output.path);
    final error = StateError('metadata failed');
    final inspectDescriptors =
        Platform.isLinux && Directory('/proc/self/fd').existsSync();
    final before = inspectDescriptors ? _openDescriptorsFor(source.path) : 0;
    try {
      await expectLater(encoder.addFile(_MetadataFailureFile(source, error)),
          throwsA(same(error)));
      if (inspectDescriptors) {
        expect(_openDescriptorsFor(source.path), before);
      }
      await encoder.addFile(source);
    } finally {
      await encoder.close();
    }
    final archive = TarDecoder().decodeBytes(output.readAsBytesSync());
    expect(archive.files, hasLength(1));
    expect(archive.files.single.readBytes(), 'data'.codeUnits);
  });

  test('cancellation preserves completed TAR entries', () async {
    final dir = Directory.systemTemp.createTempSync('archive-tar-cancel-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = Directory(p.join(dir.path, 'source'))..createSync();
    for (var i = 0; i < 3; i++) {
      File(p.join(source.path, '$i.txt')).writeAsStringSync('$i');
    }
    final output = File(p.join(dir.path, 'out.tar'));
    var calls = 0;
    await TarFileEncoder().tarDirectory(source, filename: output.path,
        filter: (_, progress) {
      expect(progress, closeTo((calls + 1) / 3, 0.00001));
      return ++calls == 2 ? ZipFileOperation.cancel : ZipFileOperation.include;
    });
    expect(calls, 2);
    final archive = TarDecoder().decodeBytes(output.readAsBytesSync());
    expect(archive.files, hasLength(1));
    expect(archive.files.single.readBytes(),
        p.basenameWithoutExtension(archive.files.single.name).codeUnits);
  });
}

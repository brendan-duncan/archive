@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

int _openDescriptorsFor(String filePath) {
  final canonical = File(filePath).resolveSymbolicLinksSync();
  var count = 0;
  for (final descriptor
      in Directory('/proc/self/fd').listSync(followLinks: false)) {
    if (descriptor is! Link) continue;
    try {
      if (descriptor.targetSync() == canonical) count++;
    } on FileSystemException {
      // The process can close a descriptor while the directory is listed.
    }
  }
  return count;
}

void main() {
  test('a rejected file entry does not keep an input handle open', () {
    if (!Platform.isLinux || !Directory('/proc/self/fd').existsSync()) {
      return;
    }
    final dir = Directory.systemTemp.createTempSync('archive-zip-fd-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final inputFile = File(p.join(dir.path, 'input.bin'))
      ..writeAsBytesSync([1, 2, 3]);
    final output = p.join(dir.path, 'archive.zip');
    final encoder = ZipFileEncoder()..create(output);
    final before = _openDescriptorsFor(inputFile.path);
    try {
      // Invalid zip names fail before the encoder's normal autoClose callback.
      expect(
        () => encoder.addFileSync(inputFile, ''.padRight(65536, 'a')),
        throwsA(isA<ArchiveException>()),
      );
      expect(_openDescriptorsFor(inputFile.path), before);
    } finally {
      encoder.closeSync();
    }
  });

  test('async directory encoding preserves progress, filtering and contents',
      () async {
    final dir = Directory.systemTemp.createTempSync('archive-zip-dir-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = Directory(p.join(dir.path, 'source'))..createSync();
    Directory(p.join(source.path, 'sub')).createSync();
    File(p.join(source.path, 'keep.txt')).writeAsStringSync('keep');
    File(p.join(source.path, 'skip.txt')).writeAsStringSync('skip');
    File(p.join(source.path, 'sub', 'nested.txt')).writeAsStringSync('nested');

    final progress = <double>[];
    final output = p.join(dir.path, 'filtered.zip');
    await ZipFileEncoder().zipDirectory(
      source,
      filename: output,
      level: ZipFileEncoder.store,
      onProgress: progress.add,
      filter: (entry, value) {
        expect(value, inInclusiveRange(0.0, 1.0));
        return p.basename(entry.path) == 'skip.txt'
            ? ZipFileOperation.skip
            : ZipFileOperation.include;
      },
    );
    final decoded = ZipDecoder().decodeBytes(
      File(output).readAsBytesSync(),
      verify: true,
    );
    expect(decoded.findFile('keep.txt')?.readBytes(), 'keep'.codeUnits);
    expect(decoded.findFile('sub/nested.txt')?.readBytes(), 'nested'.codeUnits);
    expect(decoded.findFile('skip.txt'), isNull);
    expect(progress, isNotEmpty);

    // Without callbacks no counting pass should be required.
    final unfiltered = p.join(dir.path, 'unfiltered.zip');
    await ZipFileEncoder().zipDirectory(source, filename: unfiltered);
    final all = ZipDecoder().decodeBytes(File(unfiltered).readAsBytesSync());
    expect(all.findFile('skip.txt')?.readBytes(), 'skip'.codeUnits);
  });

  test('async cancellation finalizes a valid ZIP containing completed entries',
      () async {
    final dir = Directory.systemTemp.createTempSync('archive-zip-cancel-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = Directory(p.join(dir.path, 'source'))..createSync();
    for (var i = 0; i < 3; i++) {
      File(p.join(source.path, '$i.txt')).writeAsStringSync('$i');
    }
    final output = File(p.join(dir.path, 'cancelled.zip'));
    var calls = 0;
    var progressCalls = 0;
    await ZipFileEncoder().zipDirectory(source,
        filename: output.path,
        onProgress: (_) => progressCalls++,
        filter: (_, progress) {
          expect(progress, closeTo((calls + 1) / 3, 0.00001));
          return ++calls == 2
              ? ZipFileOperation.cancel
              : ZipFileOperation.include;
        });
    expect(calls, 2);
    expect(progressCalls, 1);
    final archive =
        ZipDecoder().decodeBytes(output.readAsBytesSync(), verify: true);
    expect(archive.files, hasLength(1));
    expect(archive.files.single.readBytes(),
        p.basenameWithoutExtension(archive.files.single.name).codeUnits);
  });
}

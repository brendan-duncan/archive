@TestOn('vm')
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final extension in ['tar', 'tar.gz', 'zip']) {
    test('$extension preserves its callback policy for rejected entries',
        () async {
      final dir = Directory.systemTemp.createTempSync('archive-callback-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = Directory(p.join(dir.path, 'out'))..createSync();
      final archive = Archive()
        ..addFile(ArchiveFile.string('../outside.txt', 'should not write'))
        ..addFile(ArchiveFile.symlink('escape', '../outside.txt'))
        ..addFile(ArchiveFile.symlink('occupied', 'nested/inside.txt'))
        ..addFile(ArchiveFile.string('nested/inside.txt', 'written'));
      final occupied = File(p.join(out.path, 'occupied', 'existing.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('keep');
      final existing = File(p.join(out.path, 'nested', 'inside.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('replace');
      final tar = TarEncoder().encodeBytes(archive);
      final bytes = switch (extension) {
        'zip' => ZipEncoder().encodeBytes(archive),
        'tar.gz' => GZipEncoder().encodeBytes(tar),
        _ => tar,
      };
      final sourceFile = File(p.join(dir.path, 'in.$extension'))
        ..writeAsBytesSync(bytes);

      final observed = <String>[];
      await extractFileToDisk(sourceFile.path, out.path,
          callback: (entry) => observed.add(entry.name));

      expect(
          observed,
          extension == 'zip'
              ? ['../outside.txt', 'escape', 'occupied', 'nested/inside.txt']
              : ['nested/inside.txt']);
      expect(File(p.join(dir.path, 'outside.txt')).existsSync(), isFalse);
      expect(Link(p.join(out.path, 'escape')).existsSync(), isFalse);
      expect(occupied.readAsStringSync(), 'keep');
      expect(existing.readAsStringSync(), 'written');
      expect(
        File(p.join(out.path, 'nested', 'inside.txt')).readAsStringSync(),
        'written',
      );
    });
  }
}

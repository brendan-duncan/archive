@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tar_test.dart' show tarBlock, tarHeader;

void main() {
  late Directory dir;
  late String out;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('extract');
    out = p.join(dir.path, 'out');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ArchiveFile text(String name, String content) =>
      ArchiveFile.bytes(name, utf8.encode(content));

  group('symbolic links', () {
    test('are not written through, even in a chain', () {
      // Each link checks out on its path alone: a/b/d/../.. is a. On disk
      // a/b/d is a, so a/b/d/e is a/e, which points at out/.., and a/e/x
      // lands beside out.
      final archive = Archive()
        ..add(ArchiveFile.directory('a/b'))
        ..add(ArchiveFile.symlink('a/b/d', '..'))
        ..add(ArchiveFile.symlink('a/b/d/e', '../..'))
        ..add(text('a/e/x', 'escaped'));
      extractArchiveToDiskSync(archive, out);

      expect(File(p.join(dir.path, 'x')).existsSync(), isFalse);
      expect(File(p.join(out, 'a', 'e', 'x')).readAsStringSync(), 'escaped');
      expect(FileSystemEntity.isLinkSync(p.join(out, 'a', 'e')), isFalse);
      expect(FileSystemEntity.isLinkSync(p.join(out, 'a', 'b', 'd')), isTrue);
    });

    test('point where their target says on paths alone', () {
      // a/b/d/../.. is a on paths alone, and out/.. on disk if the target
      // were made as it is written.
      final archive = Archive()
        ..add(ArchiveFile.directory('a/b'))
        ..add(ArchiveFile.symlink('a/b/d', '..'))
        ..add(ArchiveFile.symlink('f', 'a/b/d/../..'));
      extractArchiveToDiskSync(archive, out);
      expect(FileSystemEntity.isLinkSync(p.join(out, 'a', 'b', 'd')), isTrue);
      expect(Link(p.join(out, 'f')).resolveSymbolicLinksSync(),
          Directory(p.join(out, 'a')).resolveSymbolicLinksSync());
    });

    test('to other links are still made', () {
      final archive = Archive()
        ..add(text('a.txt', 'a'))
        ..add(ArchiveFile.symlink('c', 'b'))
        ..add(ArchiveFile.symlink('b', 'a.txt'));
      extractArchiveToDiskSync(archive, out);
      expect(File(p.join(out, 'c')).readAsStringSync(), 'a');
    });

    test('from a tar hard link point at the right file', () async {
      final tar = Uint8List.fromList([
        ...tarHeader('dir/a', 1, TarFile.normalFile),
        ...tarBlock([0x61]),
        ...tarHeader('dir/b', 0, TarFile.hardLink)
          ..setRange(157, 162, ascii.encode('dir/a')),
        ...Uint8List(1024),
      ]);
      // The header checksum is not checked without verify.
      final archive = TarDecoder().decodeBytes(tar);
      expect(archive.findFile('dir/b')!.symbolicLink, 'a');
      extractArchiveToDiskSync(archive, out);
      expect(File(p.join(out, 'dir', 'b')).readAsStringSync(), 'a');
    });
  });

  test('extractTarFiles keeps entries inside the output', () {
    final archive = Archive()
      ..add(text('../outside.txt', 'escaped'))
      ..add(text('inside.txt', 'kept'));
    final path = p.join(dir.path, 'in.tar.gz');
    File(path).writeAsBytesSync(
        GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)));

    extractTarFiles(path, out);
    expect(File(p.join(dir.path, 'outside.txt')).existsSync(), isFalse);
    expect(File(p.join(out, 'inside.txt')).readAsStringSync(), 'kept');
  });

  test('an entry that fails to decode throws and leaves no file', () {
    final archive = Archive()..add(text('a.txt', 'a' * 10000));
    final zip = ZipEncoder().encodeBytes(archive);
    // Claim 100 bytes, which the entry decodes past.
    final view = ByteData.sublistView(zip);
    for (var i = 0; i + 4 <= zip.length; i++) {
      final signature = view.getUint32(i, Endian.little);
      if (signature == 0x04034b50) {
        view.setUint32(i + 22, 100, Endian.little);
      } else if (signature == 0x02014b50) {
        view.setUint32(i + 24, 100, Endian.little);
      }
    }
    final path = p.join(dir.path, 'in.zip');
    File(path).writeAsBytesSync(zip);

    expect(
        () => extractFileToDisk(path, out), throwsA(isA<ArchiveException>()));
    expect(File(p.join(out, 'a.txt')).existsSync(), isFalse);
  });
}

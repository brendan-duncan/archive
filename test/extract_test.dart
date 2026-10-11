@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A ustar header block for an entry called [name] of [size] bytes.
Uint8List tarHeader(String name, int size, String typeFlag) {
  final h = Uint8List(512);
  void put(int off, String s) =>
      h.setRange(off, off + s.length, ascii.encode(s));
  put(0, name);
  put(100, '0000644');
  put(108, '0000000');
  put(116, '0000000');
  put(124, size.toRadixString(8).padLeft(11, '0'));
  put(136, '00000000000');
  put(148, '        ');
  put(156, typeFlag);
  put(257, 'ustar');
  put(263, '00');
  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
  return h;
}

List<int> tarBlock(List<int> data) =>
    [...data, ...Uint8List((512 - data.length % 512) % 512)];

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
    });

    test('that resolve outside the output on disk are not made', () {
      // a/b/d/../.. is a on paths alone, and out/.. on disk if the target
      // were made as it is written.
      final archive = Archive()
        ..add(ArchiveFile.directory('a/b'))
        ..add(ArchiveFile.symlink('a/b/d', '..'))
        ..add(ArchiveFile.symlink('f', 'a/b/d/../..'));
      extractArchiveToDiskSync(archive, out);
      expect(FileSystemEntity.isLinkSync(p.join(out, 'a', 'b', 'd')), isTrue);
      expect(FileSystemEntity.typeSync(p.join(out, 'f'), followLinks: false),
          FileSystemEntityType.notFound);
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
      expect(archive.findFile('dir/b')!.symbolicLink, 'dir/a');
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

  test('a tar cut inside a whole gzip leaves no short file', () async {
    final tar = TarEncoder().encodeBytes(
        Archive()..add(ArchiveFile.bytes('a.bin', Uint8List(100000))));
    final path = p.join(dir.path, 'cut.tar.gz');
    File(path).writeAsBytesSync(
        GZipEncoder().encodeBytes(tar.sublist(0, 512 + 50000)));

    await extractFileToDisk(path, p.join(dir.path, 'quiet'));
    expect(File(p.join(dir.path, 'quiet', 'a.bin')).existsSync(), isFalse);

    await expectLater(
        extractFileToDisk(path, p.join(dir.path, 'strict'), throwOnError: true),
        throwsA(isA<ArchiveException>()));
    expect(File(p.join(dir.path, 'strict', 'a.bin')).existsSync(), isFalse);

    expect(() => extractTarFiles(path, p.join(dir.path, 'command')),
        throwsA(isA<ArchiveException>()));
    expect(File(p.join(dir.path, 'command', 'a.bin')).existsSync(), isFalse);
  });

  test('an entry that fails to decode leaves no file', () async {
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

    await extractFileToDisk(path, out);
    expect(File(p.join(out, 'a.txt')).existsSync(), isFalse);

    final strict = p.join(dir.path, 'strict');
    await expectLater(extractFileToDisk(path, strict, throwOnError: true),
        throwsA(isA<ArchiveException>()));
    expect(File(p.join(strict, 'a.txt')).existsSync(), isFalse);
  });
}

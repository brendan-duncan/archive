import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  group('archive', () {
    test('replace existing file', () {
      final archive = Archive();
      archive.addFile(ArchiveFile.bytes("a", Uint8List.fromList([0])));
      archive.addFile(ArchiveFile.bytes("b", Uint8List.fromList([1])));
      archive.addFile(ArchiveFile.bytes("c", Uint8List.fromList([2])));

      archive.addFile(ArchiveFile.bytes("b", Uint8List.fromList([3])));

      archive.addFile(
          ArchiveFile.bytes("陳大文_1_test.png", Uint8List.fromList([4])));

      expect(archive.length, 4);
      expect(archive[0].name, "a");
      expect(archive[1].name, "b");
      expect(archive[2].name, "c");
      expect(archive[3].name, "陳大文_1_test.png");

      expect(archive[0].getContent()!.readByte(), 0);
      expect(archive[1].getContent()!.readByte(), 3);
      expect(archive[2].getContent()!.readByte(), 2);
      expect(archive[3].getContent()!.readByte(), 4);
    });

    test('clear', () {
      final archive = Archive();
      archive.addFile(ArchiveFile.bytes("a", Uint8List.fromList([0])));
      archive.addFile(ArchiveFile.bytes("b", Uint8List.fromList([1])));
      archive.addFile(ArchiveFile.bytes("c", Uint8List.fromList([2])));
      archive.clearSync();
      expect(archive.length, 0);
    });

    test('remove file', () {
      final archive = Archive();
      final file1 = ArchiveFile.bytes("a", Uint8List.fromList([0]));
      final file2 = ArchiveFile.bytes("b", Uint8List.fromList([1]));
      archive.addFile(file1);
      archive.addFile(file2);
      expect(archive.length, 2);
      archive.removeFile(file1);
      expect(archive.length, 1);
      expect(archive[0].name, "b");
      expect(archive[0].getContent()!.readByte(), 1);
      archive.removeFile(file2);
      expect(archive.length, 0);
    });

    test('remove file at index', () {
      final archive = Archive();
      archive.addFile(ArchiveFile.bytes("a", Uint8List.fromList([0])));
      archive.addFile(ArchiveFile.bytes("b", Uint8List.fromList([1])));
      archive.removeAt(0);
      expect(archive.length, 1);
      expect(archive[0].name, "b");
      expect(archive[0].getContent()!.readByte(), 1);
      archive.removeAt(0);
      expect(archive.length, 0);
    });
  });
}

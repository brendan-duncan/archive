import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  final archive = Archive();
  for (var i = 0; i < 3; i++) {
    archive.addFile(ArchiveFile.string('file$i.txt', 'content $i'));
  }
  final bytes = ZipEncoder().encodeBytes(archive);

  group('ZipDirectory.headers', () {
    test('yields the entries read collects, and collects none itself', () {
      final directory = ZipDirectory();
      final listed = directory.headers(InputMemoryStream(bytes)).toList();
      final read = ZipDirectory()..read(InputMemoryStream(bytes));

      expect(listed.map((h) => (h.filename, h.localHeaderOffset)),
          read.fileHeaders.map((h) => (h.filename, h.localHeaderOffset)));
      expect(directory.fileHeaders, isEmpty);
    });

    test('leaves the stream where it was, walked whole or stopped early', () {
      final input = InputMemoryStream(bytes)..setPosition(5);

      ZipDirectory().headers(input).toList();
      expect(input.position, 5);
      ZipDirectory().headers(input).take(1).toList();
      expect(input.position, 5);
    });

    test('with files false yields headers without a file', () {
      final listed =
          ZipDirectory().headers(InputMemoryStream(bytes), files: false);

      expect(listed.map((h) => h.filename),
          ['file0.txt', 'file1.txt', 'file2.txt']);
      expect(listed.map((h) => h.file), everyElement(isNull));
    });

    test('with files false finds the local headers of a prefixed archive', () {
      // A prefix the central directory offset leaves out, but the local header
      // offsets count.
      const prefix = 37;
      final prefixed =
          Uint8List.fromList([...List.filled(prefix, 0x4d), ...bytes]);
      final data = ByteData.sublistView(prefixed);
      for (var i = prefix; i + 4 <= prefixed.length; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          data.setUint32(i + 42, data.getUint32(i + 42, Endian.little) + prefix,
              Endian.little);
        }
      }

      final offsets = ZipDirectory()
          .headers(InputMemoryStream(prefixed), files: false)
          .map((h) => h.localHeaderOffset)
          .toList();
      expect(offsets, [
        for (final h in ZipDirectory().headers(InputMemoryStream(bytes)))
          h.localHeaderOffset + prefix
      ]);
      for (final offset in offsets) {
        expect(data.getUint32(offset, Endian.little), 0x04034b50);
      }
    });

    test('reads a record only when it is iterated to', () {
      // Damage the second central directory record's signature.
      final damaged = Uint8List.fromList(bytes);
      final records = [
        for (var i = 0; i + 4 <= damaged.length; i++)
          if (damaged[i] == 0x50 &&
              damaged[i + 1] == 0x4b &&
              damaged[i + 2] == 0x01 &&
              damaged[i + 3] == 0x02)
            i,
      ];
      damaged[records[1]] = 0;

      expect(
          () => ZipDirectory()
              .headers(InputMemoryStream(damaged), verify: true)
              .toList(),
          throwsA(isA<ArchiveException>()));
      expect(
          ZipDirectory()
              .headers(InputMemoryStream(damaged), verify: true)
              .take(1)
              .map((h) => h.filename),
          ['file0.txt']);
    });
  });
}

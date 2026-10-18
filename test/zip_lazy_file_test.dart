import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

/// An [InputMemoryStream] that records every position it is moved to.
class _SeekRecorder extends InputMemoryStream {
  _SeekRecorder(super.bytes);

  final positions = <int>[];

  @override
  void setPosition(int v) {
    positions.add(v);
    super.setPosition(v);
  }
}

void main() {
  final archive = Archive();
  for (var i = 0; i < 3; i++) {
    archive.addFile(ArchiveFile.string('file$i.txt', 'content $i'));
  }
  final bytes = ZipEncoder().encodeBytes(archive);

  group('ZipFileHeader.file', () {
    test('listing the central directory reads no local header', () {
      final input = _SeekRecorder(bytes);
      final directory = ZipDirectory()..read(input);
      // The first local header is at 0, where the directory returns the
      // stream to once read, so only the later ones tell.
      final localHeaders = directory.fileHeaders
          .map((h) => h.localHeaderOffset)
          .where((offset) => offset > 0)
          .toSet();

      expect(directory.fileHeaders.map((h) => h.filename),
          ['file0.txt', 'file1.txt', 'file2.txt']);
      expect(input.positions.where(localHeaders.contains), isEmpty);
    });

    test('is read when first asked for and leaves the stream where it was', () {
      final input = InputMemoryStream(bytes);
      final directory = ZipDirectory()..read(input);
      input.setPosition(5);

      for (final header in directory.fileHeaders.reversed) {
        final name = header.filename;
        expect(utf8.decode(header.file!.readBytes()),
            'content ${name.substring(4, 5)}');
      }
      expect(input.position, 5);
    });

    test('a damaged local header throws on every read, not null', () {
      final damaged = Uint8List.fromList(bytes);
      final first = ZipDirectory()..read(InputMemoryStream(damaged));
      damaged[first.fileHeaders[1].localHeaderOffset] ^= 0xff;
      final input = InputMemoryStream(damaged);
      final directory = ZipDirectory()..read(input, verify: true);
      input.setPosition(5);

      final header = directory.fileHeaders[1];
      expect(() => header.file, throwsA(isA<ArchiveException>()));
      expect(() => header.file, throwsA(isA<ArchiveException>()));
      expect(input.position, 5);
      expect(
          utf8.decode(directory.fileHeaders[2].file!.readBytes()), 'content 2');
    });
  });
}

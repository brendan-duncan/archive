import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Every check is run against an archive the package itself wrote, and against
// the archives of every other format, so a header that happens to look like
// another one would show up.

Uint8List _sample() {
  final data = Uint8List(4096);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + (i >> 5)) & 0xff;
  }
  return data;
}

void main() {
  final sample = _sample();
  final archives = <ArchiveFormat, Uint8List>{
    ArchiveFormat.gzip: GZipEncoder().encodeBytes(sample),
    ArchiveFormat.zlib: ZLibEncoder().encodeBytes(sample),
    ArchiveFormat.bzip2: BZip2Encoder().encodeBytes(sample),
    ArchiveFormat.xz: XZEncoder().encodeBytes(sample),
    ArchiveFormat.zstd: ZstdEncoder().encodeBytes(sample),
    ArchiveFormat.zip: ZipEncoder()
        .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', sample))),
    ArchiveFormat.tar: TarEncoder()
        .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', sample))),
  };

  group('CodecsRecognizer', () {
    archives.forEach((format, bytes) {
      test('$format is recognised', () {
        expect(CodecsRecognizer.recognize(bytes, withZLib: true), format);
      });

      test('$format is not recognised as any other format', () {
        final checks = <ArchiveFormat, bool Function(List<int>)>{
          ArchiveFormat.gzip: CodecsRecognizer.isGZip,
          ArchiveFormat.bzip2: CodecsRecognizer.isBZip2,
          ArchiveFormat.xz: CodecsRecognizer.isXZ,
          ArchiveFormat.zstd: CodecsRecognizer.isZstd,
          ArchiveFormat.zip: CodecsRecognizer.isZip,
          ArchiveFormat.tar: CodecsRecognizer.isTar,
        };
        checks.forEach((other, check) {
          expect(check(bytes), other == format,
              reason: '$format read as $other');
        });
      });
    });

    test('zstd skippable frame at start is recognised as zstd', () {
      final frame = Uint8List.fromList([
        0x50, 0x2a, 0x4d, 0x18, // skippable magic, low byte first
        4, 0, 0, 0, // the size of what it holds
        1, 2, 3, 4,
      ]);
      expect(CodecsRecognizer.isZstd(frame), isTrue);
      expect(CodecsRecognizer.recognize(frame, withZLib: true),
          ArchiveFormat.zstd);
    });

    test('empty zip archive is recognised as zip', () {
      expect(
          CodecsRecognizer.recognize(ZipEncoder().encodeBytes(Archive()),
              withZLib: true),
          ArchiveFormat.zip);
    });

    test('empty ZIP64 archive is recognised from end record', () {
      final bytes = Uint8List(98);
      final fields = ByteData.sublistView(bytes);
      for (final entry in {
        0: 0x06064b50,
        4: 44,
        12: 0x002d002d,
        56: 0x07064b50,
        72: 1,
        76: 0x06054b50,
        84: 0xffffffff,
        88: 0xffffffff,
        92: 0xffffffff,
      }.entries) {
        fields.setUint32(entry.key, entry.value, Endian.little);
      }
      expect(ZipDecoder().decodeBytes(bytes).files, isEmpty);
      for (var length = 0; length <= bytes.length; length++) {
        final prefix = Uint8List.sublistView(bytes, 0, length);
        expect(CodecsRecognizer.isZip(prefix), length >= 4,
            reason: '$length bytes');
        expect(CodecsRecognizer.recognize(prefix, withZLib: true),
            length >= 4 ? ArchiveFormat.zip : ArchiveFormat.unknown,
            reason: '$length bytes');
      }
    });

    test('tar whose filename starts with ZIP64 magic is recognised as tar', () {
      final name = String.fromCharCodes([0x50, 0x4b, 0x06, 0x06]);
      final bytes = TarEncoder().encodeBytes(
          Archive()..add(ArchiveFile.bytes(name, Uint8List.fromList([1]))));
      expect(CodecsRecognizer.isZip(bytes), isTrue);
      expect(CodecsRecognizer.recognize(bytes), ArchiveFormat.tar);
    });

    test('zip that starts with PK00 marker is recognised as zip', () {
      final zip = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'x')));
      final marked = Uint8List.fromList([0x50, 0x4b, 0x30, 0x30, ...zip]);
      expect(
          ZipDecoder().decodeBytes(marked, verify: true).single.name, 'a.txt');
      expect(CodecsRecognizer.isZip(marked), isTrue);
      expect(CodecsRecognizer.recognize(marked), ArchiveFormat.zip);
    });

    test('every archive in test data is recognised', testOn: 'vm', () {
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/xz/cat.jpg.xz')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.xz);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/cat.jpg.gz')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.gzip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/folder.zip')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.zip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/example.tar')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.tar);
    });

    test('data matching no format is unknown', () {
      expect(CodecsRecognizer.recognize(Uint8List(0), withZLib: true),
          ArchiveFormat.unknown);
      expect(
          CodecsRecognizer.recognize(Uint8List.fromList([1, 2, 3]),
              withZLib: true),
          ArchiveFormat.unknown);
      expect(CodecsRecognizer.recognize(sample, withZLib: true),
          ArchiveFormat.unknown);
    });

    test('zlib is not recognised without valid deflate block header', () {
      // A git ref passes the two byte check. Its "0" sets the preset
      // dictionary bit
      expect(CodecsRecognizer.isZLib('80cc39b4'.codeUnits), isFalse);
      // Type 3 is reserved
      expect(CodecsRecognizer.isZLib([0x78, 0x01, 0x06]), isFalse);
      // NLEN is not the inverse of LEN in this stored block
      expect(CodecsRecognizer.isZLib([0x78, 0x01, 0x01, 5, 0, 0, 0]), isFalse);
      for (var level = 0; level <= 9; level++) {
        for (final input in [sample, Uint8List(0)]) {
          expect(
              CodecsRecognizer.isZLib(
                  ZLibEncoder().encodeBytes(input, level: level)),
              isTrue,
              reason: 'level $level, ${input.length} bytes');
        }
      }
    });

    test('reserved header bits or missing bzip2 block are not recognised', () {
      final gzip = Uint8List.fromList(archives[ArchiveFormat.gzip]!)
        ..[3] |= 0x20;
      expect(CodecsRecognizer.isGZip(gzip), isFalse);
      final zstd = Uint8List.fromList(archives[ArchiveFormat.zstd]!)
        ..[4] |= 0x08;
      expect(CodecsRecognizer.isZstd(zstd), isFalse);
      // We change the check type. The stream flags no longer match their CRC32
      final xz = Uint8List.fromList(archives[ArchiveFormat.xz]!)..[7] ^= 0x01;
      expect(CodecsRecognizer.isXZ(xz), isFalse);
      // This text starts with the bzip2 magic. The next six bytes are not a
      // block magic
      expect(
          CodecsRecognizer.isBZip2('BZh9 is not a block'.codeUnits), isFalse);
      expect(CodecsRecognizer.isBZip2(BZip2Encoder().encodeBytes([])), isTrue);
    });

    test('header shorter than check needs is not recognised', () {
      final xz = archives[ArchiveFormat.xz]!;
      expect(CodecsRecognizer.isXZ(Uint8List.sublistView(xz, 0, 5)), isFalse);
      final tar = archives[ArchiveFormat.tar]!;
      expect(
          CodecsRecognizer.isTar(Uint8List.sublistView(tar, 0, 262)), isFalse);
    });

    test('first 6 bytes recognise every format except tar', () {
      archives.forEach((format, bytes) {
        if (format == ArchiveFormat.tar) {
          return;
        }
        final head = Uint8List.sublistView(bytes, 0, 6);
        expect(CodecsRecognizer.recognize(head, withZLib: true), format,
            reason: '$format from ${6} bytes');
      });
    });

    test('ustar tar is recognised from magic without checksum', testOn: 'vm',
        () {
      // What this package writes carries the ustar magic as well, and a tar
      // from elsewhere shows the short path for other writers
      final tar = File(p.join('test/_data/example.tar')).readAsBytesSync();
      final head = Uint8List.sublistView(tar, 0, 263);
      expect(CodecsRecognizer.isTar(head), isTrue);
      expect(
          CodecsRecognizer.recognize(head, withZLib: true), ArchiveFormat.tar);
    });

    test('tar written by TarEncoder is recognised from magic', () {
      final tar = archives[ArchiveFormat.tar]!;
      for (final length in [263, 300, 511, 512]) {
        final head = Uint8List.sublistView(tar, 0, length);
        expect(CodecsRecognizer.isTar(head), isTrue, reason: '$length bytes');
        expect(CodecsRecognizer.recognize(head), ArchiveFormat.tar,
            reason: '$length bytes');
      }
      final named = TarEncoder().encodeBytes(
          Archive()..add(ArchiveFile.string('BZh11AY&SY.txt', 'content')));
      expect(CodecsRecognizer.recognize(Uint8List.sublistView(named, 0, 300)),
          ArchiveFormat.tar);
    });

    test('tar with damaged header checksum is not recognised', () {
      final broken = Uint8List.fromList(archives[ArchiveFormat.tar]!)
        ..[100] ^= 0xff;
      expect(CodecsRecognizer.isTar(Uint8List.sublistView(broken, 0, 512)),
          isFalse);
    });

    test('every format reports its file extension', () {
      expect(
          CodecsRecognizer.extensionOf(ArchiveFormat.zstd).toString(), 'zst');
      expect(CodecsRecognizer.extensionOf(ArchiveFormat.unknown), isNull);
    });
  });
}

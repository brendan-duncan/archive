import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_test_util.dart';

final zipTests = <dynamic>[
  {
    'Name': 'test/_data/zip/test.zip',
    'Comment': 'This is a zipfile comment.',
    'File': [
      {
        'Name': 'test.txt',
        'Content': 'This is a test text file.\n'.codeUnits,
        'Mtime': '09-05-10 12:12:02',
        'Mode': 0644,
      },
      {
        'Name': 'gophercolor16x16.png',
        'File': 'gophercolor16x16.png',
        'Mtime': '09-05-10 15:52:58',
        'Mode': 0644,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/test-trailing-junk.zip',
    'Comment': 'This is a zipfile comment.',
    'File': [
      {
        'Name': 'test.txt',
        'Content': 'This is a test text file.\n'.codeUnits,
        'Mtime': '09-05-10 12:12:02',
        'Mode': 0644,
      },
      {
        'Name': 'gophercolor16x16.png',
        'File': 'gophercolor16x16.png',
        'Mtime': '09-05-10 15:52:58',
        'Mode': 0644,
      },
    ],
  },
  /*{
    'Name':   'test/_data/zip/r.zip',
    'Source': returnRecursiveZip,
    'File': [
      {
        'Name':    'r/r.zip',
        'Content': rZipBytes(),
        'Mtime':   '03-04-10 00:24:16',
        'Mode':    0666,
      },
    ],
  },*/
  {
    'Name': 'test/_data/zip/symlink.zip',
    'File': [
      {
        'Name': 'symlink',
        'Content': '../target'.codeUnits,
        'Mode': 0777 | 0120000,
        'isSymbolicLink': true,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/readme.zip',
  },
  {
    'Name': 'test/_data/zip/readme.notzip',
    //'Error': ErrFormat,
  },
  {
    'Name': 'test/_data/zip/dd.zip',
    'File': [
      {
        'Name': 'filename',
        'Content': 'This is a test textfile.\n'.codeUnits,
        'Mtime': '02-02-11 13:06:20',
        'Mode': 0666,
      },
    ],
  },
  {
    // created in windows XP file manager.
    'Name': 'test/_data/zip/winxp.zip',
    'File': [
      {'Name': 'hello', 'isFile': true},
      {'Name': 'dir/bar', 'isFile': true},
      {
        'Name': 'dir/empty/',
        'Content': <int>[], // empty list of codeUnits - no content
        'isFile': false
      },
      {'Name': 'readonly', 'isFile': true},
    ]
  },
  /*
  {
    // created by Zip 3.0 under Linux
    'Name': 'test/_data/zip/unix.zip',
    'File': crossPlatform,
  },*/
  {
    'Name': 'test/_data/zip/go-no-datadesc-sig.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/go-with-datadesc-sig.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mode': 0666,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mode': 0666,
      },
    ],
  },
  /*{
    'Name':   'Bad-CRC32-in-data-descriptor',
    'Source': returnCorruptCRC32Zip,
    'File': [
      {
        'Name':       'foo.txt',
        'Content':    'foo\n'.codeUnits,
        'Mode':       0666,
        'ContentErr': ErrChecksum,
      },
      {
        'Name':    'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mode':    0666,
      },
    ],
  },*/
  // Tests that we verify (and accept valid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name': 'test/_data/zip/crc32-not-streamed.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
      },
    ],
  },
  // Tests that we verify (and reject invalid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name': 'test/_data/zip/crc32-not-streamed.zip',
    //'Source': returnCorruptNotStreamedZip,
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
        'VerifyChecksum': true
        //'ContentErr': ErrChecksum,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
        'VerifyChecksum': true
      },
    ],
  },
  {
    'Name': 'test/_data/zip/zip64.zip',
    'File': [
      {
        'Name': 'README',
        'Content': 'This small file is in ZIP64 format.\n'.codeUnits,
        'Mtime': '08-10-12 14:33:32',
        'Mode': 0644,
      },
    ],
  },
];

void main() async {
  group('zip', () {
    test('EOCD may span two reverse-search chunks', () {
      final dir = Directory.systemTemp.createTempSync('archive-comment-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final size in [
        0,
        1005,
        1006,
        1007,
        1008,
        1009,
        1010,
        2030,
        2031,
        2032,
        2033,
        2034,
        65535
      ]) {
        final content = 'known payload' * 400;
        final archive = Archive()
          ..comment = 'x' * size
          ..addFile(ArchiveFile.string('hello.txt', content));
        final bytes = ZipEncoder().encodeBytes(archive, level: 0);
        final path = '${dir.path}/fixture.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoded = ZipDecoder().decodeStream(input);
            expect(decoded.length, 1,
                reason: 'comment=$size, ${input.runtimeType}');
            expect(decoded.first.content, content.codeUnits);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('short malformed streams terminate', () {
      for (var length = 0; length < 9; length++) {
        expect(ZipDecoder().decodeBytes(List.filled(length, 0)), isEmpty);
      }
    });

    test('EOCD remains covered when approaching the first chunk', () {
      final dir = Directory.systemTemp.createTempSync('archive-first-chunk-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final empty = ZipEncoder().encodeBytes(
          Archive()..addFile(ArchiveFile.string('data.bin', '')),
          level: 0);
      final overhead = empty.length - 22;
      for (var position = 1020; position <= 1024; position++) {
        for (var comment = 1006; comment <= 1010; comment++) {
          final content = 'a' * (position - overhead);
          final bytes = ZipEncoder().encodeBytes(
              Archive()
                ..comment = 'x' * comment
                ..addFile(ArchiveFile.string('data.bin', content)),
              level: 0);
          expect(bytes.length - 22 - comment, position);
          final path = '${dir.path}/fixture.zip';
          File(path).writeAsBytesSync(bytes);
          for (final createInput in <InputStream Function()>[
            () => InputMemoryStream(bytes),
            () => InputFileStream(path)
          ]) {
            final input = createInput();
            try {
              final decoder = ZipDecoder();
              final archive = decoder.decodeStream(input);
              expect(decoder.directory.filePosition, position,
                  reason:
                      'position=$position comment=$comment ${input.runtimeType}');
              expect(archive.length, 1);
              expect(archive.first.content, content.codeUnits);
            } finally {
              input.closeSync();
            }
          }
        }
      }
    });

    test('the EOCD of a nested zip is not mistaken for the outer one', () {
      final dir = Directory.systemTemp.createTempSync('archive-nested-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inner = ZipEncoder().encodeBytes(
          Archive()..addFile(ArchiveFile.string('inner.txt', 'i' * 50)),
          level: 0);
      // The padding shifts the nested archive's own EOCD away from the end of
      // the outer file, so the search meets it both inside the first chunk it
      // reads and several chunks in.
      for (final pad in [0, 1, 2, 20, 500, 1000, 1024, 1100, 2048]) {
        final outer = Archive()
          ..addFile(ArchiveFile.bytes('inner.zip', Uint8List.fromList(inner)))
          ..addFile(ArchiveFile.string('pad.txt', 'p' * pad));
        final bytes = ZipEncoder().encodeBytes(outer, level: 0);
        final path = '${dir.path}/nested.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoder = ZipDecoder();
            final archive = decoder.decodeStream(input);
            expect(decoder.directory.filePosition, bytes.length - 22,
                reason: 'pad=$pad, ${input.runtimeType}');
            expect(archive.length, 2);
            expect(archive.findFile('inner.zip')!.content, inner);
            expect(archive.findFile('pad.txt')!.content.length, pad);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('a signature in the trailing comment bytes is too late to be an EOCD',
        () {
      final dir = Directory.systemTemp.createTempSync('archive-tail-sig-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final content = 'known payload' * 400;
      // A record needs 22 bytes, so a signature closer than that to the end of
      // the file cannot start one and must not end the search.
      for (var trailing = 0; trailing <= 22 - 4 - 1; trailing++) {
        final comment = '${'x' * 40}PK${'y' * trailing}';
        final bytes = ZipEncoder().encodeBytes(
            Archive()
              ..comment = comment
              ..addFile(ArchiveFile.string('hello.txt', content)),
            level: 0);
        final path = '${dir.path}/tail.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoder = ZipDecoder();
            final archive = decoder.decodeStream(input);
            expect(decoder.directory.filePosition,
                bytes.length - 22 - comment.length,
                reason: 'trailing=$trailing, ${input.runtimeType}');
            expect(archive.length, 1);
            expect(archive.first.content, content.codeUnits);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('ArchiveFile compression level', () async {
      final testArchive = Archive();
      final list = Uint8List(1000);
      for (var i = 0; i < list.length; i++) {
        list[i] = i % 256;
      }
      final f = ArchiveFile.bytes('test', list);
      final f2 = ArchiveFile.bytes('test2', list);
      testArchive.addFile(f);
      testArchive.addFile(f2);

      final zipBytes = ZipEncoder().encode(testArchive);

      f.compression = CompressionType.none;
      final zipBytes2 = ZipEncoder().encode(testArchive);

      // Using no compression should result in a larger zip
      expect(zipBytes.length, lessThan(zipBytes2.length));

      final archive2 = ZipDecoder().decodeBytes(zipBytes2);
      // Verify the compression method decoded from the zip is preserved.
      expect(archive2.files[0].compression, CompressionType.none);
      expect(archive2.files[1].compression, CompressionType.deflate);

      f.compression = CompressionType.deflate;
      f.compressionLevel = 9;
      f2.compressionLevel = 9;
      final zipBytes3 = ZipEncoder().encode(testArchive);

      // Higher compression level should result in a smaller zip
      expect(zipBytes.length, greaterThan(zipBytes3.length));
    });

    test('encode file stream', () async {
      final input = InputFileStream('test/_data/zip/android-javadoc.zip');
      final output = OutputFileStream('$testOutputPath/encode_file_stream.zip');
      final archive = Archive();
      archive.add(ArchiveFile.stream('android-javadoc.zip', input));
      ZipEncoder().encodeStream(archive, output);

      final archive2 = ZipDecoder().decodeStream(InputMemoryStream(
          File('$testOutputPath/encode_file_stream.zip').readAsBytesSync()));

      input.reset();
      expect(archive2.length, 1);
      expect(archive2[0].name, 'android-javadoc.zip');
      expect(archive2[0].size, input.length);
      final content = archive2[0].content;
      expect(content.length, input.length);
    });

    test('file close', () async {
      final input = InputFileStream('test/_data/test2.zip');
      final archive = ZipDecoder().decodeStream(input);
      final f1 = archive[1];
      final f2 = archive[3];
      f1.closeSync();
      final f2content = f2.content;
      expect(f2content.length, 3);
    });

    test('memory file close', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final f1 = archive[1];
      final f2 = archive[3];
      f1.closeSync();
      final f2content = f2.content;
      expect(f2content.length, 3);
    });

    test('shared file', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final archive2 = Archive()..add(archive[1]);
      final zip = ZipEncoder().encodeBytes(archive2, autoClose: true);
      final archive3 = ZipDecoder().decodeBytes(zip);
      expect(archive3.length, 1);
      expect(archive3[0].name, archive[1].name);
      final b1 = archive3[0].content;
      final b2 = archive[1].content;
      compareBytes(b1, b2);
    });

    test('empty', () async {
      final archive = Archive();
      final encoded = ZipEncoder().encodeBytes(archive);
      final decoded = ZipDecoder().decodeBytes(encoded);
      expect(decoded.length, equals(0));
    });

    test('decode 0 bytes', () async {
      final archive = ZipDecoder().decodeBytes(Uint8List(0));
      expect(archive.length, equals(0));
    });

    test('normalizes backslash path separators', () async {
      // Regression test for #411: Windows-style paths with backslashes must
      // be normalized to forward slashes, as required by the zip format.
      final archive = Archive();
      archive.add(ArchiveFile('dir_name\\file_name', 3, [1, 2, 3]));
      archive.add(ArchiveFile.directory('sub_dir\\nested'));

      final encoded = ZipEncoder().encodeBytes(archive);
      final decoded = ZipDecoder().decodeBytes(encoded);

      final names = decoded.map((f) => f.name).toList();
      for (final name in names) {
        expect(name, isNot(contains('\\')));
      }
      expect(names, contains('dir_name/file_name'));
      expect(names, contains('sub_dir/nested/'));
    });

    test('apk', () async {
      final archive = Archive()
        ..addFile(
            ArchiveFile.bytes('AndroidManifest.xml', List<int>.filled(100, 0)));

      final apk = ZipEncoder().encode(archive);

      final decodedArchive = ZipDecoder().decodeBytes(apk);
      for (final archiveFile in decodedArchive.files) {
        expect(archiveFile.rawContent, isNotNull);
        expect(archiveFile.rawContent!.length, 6);
      }
    });

    test('zip file data: memory stream', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final file = archive[1];
      file.closeSync();
      expect(file.rawContent, isNotNull);
    });

    test('encode already compressed file', () {
      final testArchive = Archive();
      testArchive.addFile(ArchiveFile.bytes('test', [1, 2, 3]));

      final testArchiveBytes =
          ZipEncoder().encode(testArchive, level: DeflateLevel.bestCompression);

      final decodedTestArchive = ZipDecoder().decodeBytes(testArchiveBytes);

      // Verify that the archive file is already compressed and will be
      // compressed when re-encoded.
      expect(decodedTestArchive.files.single.isCompressed, true);

      final decodedTestArchiveBytes = ZipEncoder()
          .encode(decodedTestArchive, level: DeflateLevel.bestCompression);

      final verifyArchive = ZipDecoder().decodeBytes(decodedTestArchiveBytes);
      expect(verifyArchive.single.content, [1, 2, 3]);
    });

    test('re-encode after reading content', () {
      // https://github.com/brendan-duncan/archive/issues/374
      // Reading a file's content caches the decompressed data, which should
      // not cause the still-compressed rawContent to be compressed a second
      // time when the archive is re-encoded.
      final text = 'Hello World! ' * 10;
      final archive = Archive()..addFile(ArchiveFile.string('test.txt', text));
      final zipBytes = ZipEncoder().encode(archive);

      final decodedArchive = ZipDecoder().decodeBytes(zipBytes);
      final file = decodedArchive.findFile('test.txt')!;

      // Trigger decompression, caching the decompressed content.
      expect(utf8.decode(file.content), text);
      expect(file.isCompressed, true);

      final reEncodedZipBytes = ZipEncoder().encode(decodedArchive);

      final verifyArchive =
          ZipDecoder().decodeBytes(reEncodedZipBytes, verify: true);
      final verifyFile = verifyArchive.findFile('test.txt')!;
      expect(utf8.decode(verifyFile.content), text);
    });

    test('decode encode', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));

      final zipBytes = ZipEncoder().encodeBytes(archive);

      final archive2 = ZipDecoder().decodeBytes(zipBytes);

      expect(archive.length, archive2.length);
    });

    test('decode file stream', () async {
      final input = InputFileStream('test/_data/zip/android-javadoc.zip',
          bufferSize: 32 * 1024);
      final archive = ZipDecoder().decodeStream(input);
      await extractArchiveToDisk(
          archive, '$testOutputPath/zip_decode_file_stream');
    });

    test('decode', () async {
      var file = File(p.join('test/_data/zip/android-javadoc.zip'));
      var bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(102));
    });

    test('empty directory', () {
      final archive = Archive();
      archive.add(ArchiveFile.directory('empty'));
      final encodedBytes = ZipEncoder().encodeBytes(archive);
      File(p.join(testOutputPath, 'empty_directory.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);
      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 1);
      expect(archiveDecoded[0].isFile, false);
      expect(archiveDecoded[0].name, 'empty/');
    });

    test('file decode utf file', () {
      var bytes = File(p.join('test/_data/zip/utf.zip')).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(5));
    });

    test('file stream encode', () {
      final fileStream = InputFileStream('test/_data/cat.jpg');
      final archiveFile = ArchiveFile.stream('cat.jpg', fileStream);
      final archive = Archive()..add(archiveFile);
      final encodedBytes = ZipEncoder().encodeBytes(archive);
      File(p.join(testOutputPath, 'file_stream.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);
      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 1);
    });

    test('file encoding zip file', () {
      final originalFileName = 'fileöäüÖÄÜß.txt';
      final bytes = Utf8Codec().encode('test');
      final archive = Archive();
      archive.add(ArchiveFile.bytes(originalFileName, bytes));

      archive.add(ArchiveFile.directory('foo'));
      archive.add(ArchiveFile.string('foo/bar.txt', '123'));

      var encodedBytes = ZipEncoder().encodeBytes(archive);

      File(p.join(testOutputPath, 'zip_encoder.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);

      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 3);

      final decodedFile = archiveDecoded[0];

      expect(decodedFile.name, originalFileName);
    });

    test('zip64', () {
      var bytes =
          File(p.join('test/_data/zip/zip64_archive.zip')).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      expect(archive.length, equals(3));
      expect(archive[0].size, equals(3136));
    });

    test('data types', () {
      final archive = Archive();
      archive.add(ArchiveFile.bytes('uint8list', Uint8List(2)));
      archive.add(ArchiveFile.bytes('list_int', Uint8List.fromList([1, 2])));
      archive.add(ArchiveFile.typedData(
          'float32list', Float32List.fromList([3.0, 4.0])));
      archive.add(ArchiveFile.string('string', 'hello'));
      final zipData = ZipEncoder().encodeBytes(archive);
      File('$testOutputPath/zip64.zip')
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final archive2 = ZipDecoder().decodeBytes(zipData);
      expect(archive2.length, equals(archive.length));
    });

    test('encode', () {
      final archive = Archive();
      final bdata = 'hello world';
      final bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'abc.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      final zipData = ZipEncoder().encodeBytes(archive);

      File(p.join(testOutputPath, 'uncompressed.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final arc = ZipDecoder().decodeBytes(zipData, verify: true);
      expect(arc.length, equals(1));
      final arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bytes.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bytes[i]));
      }
    });

    test('encode with timestamp', () {
      final archive = Archive();
      var bdata = 'some file data';
      var bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'somefile.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      var zipData = ZipEncoder().encodeBytes(archive,
          modified: DateTime.utc(2010, DateTime.january, 1));

      File(p.join(testOutputPath, 'uncompressed.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      var arc = ZipDecoder().decodeBytes(zipData, verify: true);
      expect(arc.length, equals(1));
      var arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bdata.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bdata.codeUnits[i]));
      }
      expect(arc[0].lastModTime, equals(1008795648));
    });

    test('zipCrypto', () {
      var file = File(p.join('test/_data/zip/zipCrypto.zip'));
      var bytes = file.readAsBytesSync();
      final archive =
          ZipDecoder().decodeBytes(bytes, verify: false, password: '12345');

      expect(archive.length, equals(2));

      for (var i = 0; i < archive.length; ++i) {
        var file = File(p.join('test/_data/zip/${archive[i].name}'));
        var bytes = file.readAsBytesSync();
        var content = archive[i].readBytes()!;
        expect(bytes.length, equals(content.length));
        bool diff = false;
        for (int i = 0; i < bytes.length; ++i) {
          if (bytes[i] != content[i]) {
            diff = true;
            break;
          }
        }
        expect(diff, equals(false));
      }
    });

    test('aes256', () {
      final stream = InputFileStream('test/_data/zip/aes256.zip');
      final archive = ZipDecoder().decodeStream(stream, password: '12345');

      expect(archive.length, equals(2));
      for (var i = 0; i < archive.length; ++i) {
        final file = File(p.join('test/_data/zip/${archive[i].name}'));
        final bytes = file.readAsBytesSync();
        final content = archive[i].readBytes()!;
        expect(content.length, equals(bytes.length));
        bool diff = false;
        for (int i = 0; i < bytes.length; ++i) {
          if (bytes[i] != content[i]) {
            diff = true;
            break;
          }
        }
        expect(diff, equals(false));
      }
    });

    test('password', () {
      var file = File(p.join('test/_data/zip/password_zipcrypto.zip'));
      var bytes = file.readAsBytesSync();

      var b = File(p.join('test/_data/zip/hello.txt'));
      final bBytes = b.readAsBytesSync();

      final archive =
          ZipDecoder().decodeBytes(bytes, verify: true, password: 'test1234');
      expect(archive.length, equals(1));

      for (var i = 0; i < archive.length; ++i) {
        final zBytes = archive[i].readBytes()!;
        if (archive[i].name == 'hello.txt') {
          compareBytes(zBytes, bBytes);
        } else {
          throw TestFailure('Invalid file found');
        }
      }
    });

    test('decode zip bzip2', () {
      var file = File(p.join('test/_data/zip/zip_bzip2.zip'));
      var bytes = file.readAsBytesSync();

      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(2));

      for (final f in archive) {
        final c = f.getContent()?.toUint8List();
        expect(c, isNotNull);
      }
    });

    group('zstd', () {
      // Entries using method 93, zstd, and one deflated, made by
      // test/_data/zstd/gen_fixtures.js from files in test/_data/zip.
      final expected = {
        for (final name in [
          'hello.txt',
          'gophercolor16x16.png',
          'readme.notzip'
        ])
          name: File('test/_data/zip/$name').readAsBytesSync(),
      };

      void checkContents(Archive archive) {
        expect(archive.length, equals(3));
        for (final f in archive) {
          compareBytes(f.readBytes()!, expected[f.name]!);
        }
      }

      test('decode', () {
        final bytes = File('test/_data/zstd/zstd.zip').readAsBytesSync();
        final archive = ZipDecoder().decodeBytes(bytes, verify: true);
        checkContents(archive);
        expect(
            archive.findFile('hello.txt')!.compression, CompressionType.zstd);
        expect(archive.findFile('readme.notzip')!.compression,
            CompressionType.deflate);
      });

      test('reencoding keeps the zstd data and its method', () {
        final bytes = File('test/_data/zstd/zstd.zip').readAsBytesSync();
        final zipped = ZipEncoder()
            .encodeBytes(ZipDecoder().decodeBytes(bytes, verify: true));
        final archive = ZipDecoder().decodeBytes(zipped, verify: true);
        checkContents(archive);
        expect(archive.findFile('gophercolor16x16.png')!.compression,
            CompressionType.zstd);
      });

      test('encode', () {
        final archive = Archive();
        for (final e in expected.entries) {
          archive.add(ArchiveFile.bytes(e.key, e.value)
            ..compression = CompressionType.zstd);
        }
        final zipped = ZipEncoder().encodeBytes(archive);
        final decoded = ZipDecoder().decodeBytes(zipped, verify: true);
        checkContents(decoded);
        for (final f in decoded) {
          expect(f.compression, CompressionType.zstd);
        }
      });
    });

    group('streamed entries', () {
      // An entry that is not compressed yet is compressed straight into the
      // output, so its header goes out before the CRC and sizes are known
      // and they follow the data in a data descriptor.
      late Uint8List content;
      late String path;

      setUp(() {
        final r = Random(7);
        // Compressible, but not trivially so, and longer than the chunks
        // the encoders work in. Not a multiple of the AES block size.
        content = Uint8List.fromList(List.generate(
            200 * 1024 + 7, (i) => i % 251 == 0 ? r.nextInt(256) : (i >> 3)));
        path = p.join(testOutputPath, 'streamed.bin');
        File(path)
          ..createSync(recursive: true)
          ..writeAsBytesSync(content);
      });

      void checkStreamed(Uint8List zipped, CompressionType compression,
          {String? password}) {
        final header = InputMemoryStream(zipped);
        header.setPosition(6);
        expect(header.readUint16() & ZipEncoder.dataDescriptorBit,
            ZipEncoder.dataDescriptorBit);
        // The CRC was not known when the header was written.
        header.setPosition(14);
        expect(header.readUint32(), 0);

        final file = File(p.join(testOutputPath, 'streamed.zip'))
          ..writeAsBytesSync(zipped);
        final fileInput = InputFileStream(file.path);
        for (final archive in [
          ZipDecoder().decodeBytes(zipped, password: password),
          ZipDecoder().decodeStream(fileInput, password: password),
        ]) {
          expect(archive.length, 1);
          final entry = archive.first;
          expect(entry.name, 'streamed.bin');
          expect(entry.size, content.length);
          expect(entry.compression, compression);
          expect(entry.crc32, getCrc32(content));
          expect((entry.rawContent as ZipFile).verifyCrc32(), isTrue);
          compareBytes(entry.readBytes()!, content);
        }
        fileInput.closeSync();
      }

      for (final compression in CompressionType.values) {
        test('$compression', () {
          final stream = InputFileStream(path);
          final archive = Archive()
            ..add(ArchiveFile.stream('streamed.bin', stream)
              ..compression = compression);
          final zipped = ZipEncoder().encodeBytes(archive);
          stream.closeSync();
          checkStreamed(zipped, compression);
        });
      }

      test('encrypted', () {
        final stream = InputFileStream(path);
        final archive = Archive()
          ..add(ArchiveFile.stream('streamed.bin', stream));
        final zipped = ZipEncoder(password: 'secret').encodeBytes(archive);
        stream.closeSync();
        checkStreamed(zipped, CompressionType.deflate, password: 'secret');
        // Decoding is lazy, so a wrong password only shows when the
        // content is read.
        expect(
            () => ZipDecoder()
                .decodeBytes(zipped, password: 'wrong')
                .first
                .readBytes(),
            throwsA(isA<ArchiveException>()));
        expect(() => ZipDecoder().decodeBytes(zipped).first.readBytes(),
            throwsA(isA<ArchiveException>()));

        // Decrypted as it is read, and readable more than once.
        final entry =
            ZipDecoder().decodeBytes(zipped, password: 'secret').first;
        final zf = entry.rawContent as ZipFile;
        expect(zf.verifyCrc32(), isTrue);
        final out = OutputMemoryStream();
        zf.decompress(out);
        compareBytes(out.getBytes(), content);
        compareBytes(zf.getStream().toUint8List(), content);
        compareBytes(entry.readBytes()!, content);
        // The stored form is the compressed data, which still decodes.
        compareBytes(
            ZLibDecoder().decodeBytes(
                zf.getStream(decompress: false).toUint8List(),
                raw: true),
            content);
      });

      test('zipCrypto entries are decrypted as they are read', () {
        final bytes = File('test/_data/zip/zipCrypto.zip').readAsBytesSync();
        final archive = ZipDecoder().decodeBytes(bytes, password: '12345');
        for (final entry in archive) {
          final zf = entry.rawContent as ZipFile;
          expect(zf.verifyCrc32(), isTrue, reason: entry.name);
          final expected =
              File('test/_data/zip/${entry.name}').readAsBytesSync();
          compareBytes(entry.readBytes()!, expected);
          // Again: the archive bytes were not decrypted in place.
          compareBytes(entry.readBytes()!, expected);
        }
        expect(
            () => ZipDecoder()
                .decodeBytes(bytes, password: 'wrong')
                .first
                .readBytes(),
            throwsA(anything));
      });

      test('zip64 data descriptor', () {
        // An entry that says it is larger than 4 GB gets a zip64 extra field
        // in its local header, which makes the sizes in the data descriptor
        // 8 bytes wide. The content is small, so the test is only that both
        // sides agree on the layout.
        final stream = InputFileStream(path);
        final archive = Archive()
          ..add(ArchiveFile.file('streamed.bin', 5 * 1024 * 1024 * 1024,
              FileContentStream(stream)));
        final zipped = ZipEncoder().encodeBytes(archive);
        stream.closeSync();

        final header = InputMemoryStream(zipped);
        header.setPosition(18);
        expect(header.readUint32(), 0xFFFFFFFF); // compressed size
        expect(header.readUint32(), 0xFFFFFFFF); // uncompressed size
        header.setPosition(28);
        final extraLength = header.readUint16();
        expect(extraLength, 20);
        header.setPosition(30 + 'streamed.bin'.length);
        expect(header.readUint16(), 1); // zip64 extra field id

        checkStreamed(zipped, CompressionType.deflate);
      });
    });

    test('encode password', () {
      final archive = Archive();
      final bdata = 'hello world';
      final bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'abc.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      final zipData = ZipEncoder(password: 'abc123').encodeBytes(archive);

      File(p.join(testOutputPath, 'zip_password.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final arc = ZipDecoder().decodeBytes(zipData, password: 'abc123');
      expect(arc.length, equals(1));
      final arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bdata.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bdata.codeUnits[i]));
      }
    });

    test('decode/encode', () {
      final file = File(p.join('test/_data/test.zip'));
      final bytes = file.readAsBytesSync();

      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(2));

      final b = File(p.join('test/_data/cat.jpg'));
      final bBytes = b.readAsBytesSync();
      final aBytes = aTxt.codeUnits;

      for (var i = 0; i < archive.length; ++i) {
        final zBytes = archive[i].readBytes()!;
        if (archive[i].name == 'a.txt') {
          compareBytes(zBytes, aBytes);
        } else if (archive[i].name == 'cat.jpg') {
          compareBytes(zBytes, bBytes);
        } else {
          throw TestFailure('Invalid file found');
        }
      }

      // Encode the archive we just decoded
      final zipped = ZipEncoder().encodeBytes(archive);

      final f = File(p.join(testOutputPath, 'test.zip'));
      f.createSync(recursive: true);
      f.writeAsBytesSync(zipped);

      // Decode the archive we just encoded
      final archive2 = ZipDecoder().decodeBytes(zipped, verify: true);

      expect(archive2.length, equals(archive.length));
      for (var i = 0; i < archive2.length; ++i) {
        expect(archive2[i].name, equals(archive[i].name));
        expect(archive2[i].size, equals(archive[i].size));
      }
    });

    test('symlink', () async {
      final stream = InputMemoryStream(
          File('test/_data/zip/symlink.zip').readAsBytesSync());
      final archive = ZipDecoder().decodeStream(stream);
      expect(archive[0].isSymbolicLink, equals(true));
    });

    test('decode many files (100k)', () async {
      final fp = InputFileStream(
        p.join('test/_data/test_100k_files.zip'),
        bufferSize: 1024 * 1024,
      );
      final archive = ZipDecoder().decodeStream(fp);

      final totalArchiveEntriesCount = archive.length;
      expect(archive.length, equals(100000));

      int nextEntryIndex = 0;
      while (nextEntryIndex < totalArchiveEntriesCount) {
        final file = archive[nextEntryIndex];
        if (!file.isFile) {
          nextEntryIndex++;
          continue;
        }
        final f = file;
        final String filename = f.name;
        final data = f.getContent();
        f.clear();
        expect(
          filename.trim(),
          isNotEmpty,
          reason: 'Archive file check error: file name empty',
        );
        expect(
          data,
          isNotNull,
          reason: 'Archive file check error: content for $filename is null',
        );
        nextEntryIndex++;
      }
    });

    for (final Z in zipTests) {
      final z = Z as Map<String, dynamic>;
      test('unzip ${z['Name']}', () {
        final file = File(p.join(z['Name'] as String));
        final bytes = file.readAsBytesSync();

        final zipDecoder = ZipDecoder();
        final archive = zipDecoder.decodeBytes(bytes, verify: true);
        final zipFiles = zipDecoder.directory.fileHeaders;

        if (z.containsKey('Comment')) {
          expect(zipDecoder.directory.zipFileComment, z['Comment']);
        }

        if (!z.containsKey('File')) {
          return;
        }
        expect(zipFiles.length, equals(z['File'].length));

        for (var i = 0; i < zipFiles.length; ++i) {
          final zipFileHeader = zipFiles[i];
          final zipFile = zipFileHeader.file;

          final hdr = z['File'][i] as Map<String, dynamic>;

          if (hdr.containsKey('Name')) {
            expect(zipFile!.filename, equals(hdr['Name']));
          }
          if (hdr.containsKey('Content')) {
            expect(zipFile!.getStream().toUint8List(), equals(hdr['Content']));
          }
          if (hdr.containsKey('VerifyChecksum')) {
            expect(zipFile!.verifyCrc32(), equals(hdr['VerifyChecksum']));
          }
          if (hdr.containsKey('isFile')) {
            expect(archive.find(zipFile!.filename)?.isFile, hdr['isFile']);
          }
          if (hdr.containsKey('isSymbolicLink')) {
            expect(archive.find(zipFile!.filename)?.isSymbolicLink,
                hdr['isSymbolicLink']);
            expect(archive.find(zipFile.filename)?.symbolicLink,
                utf8.decode(hdr['Content'] as List<int>));
          }
        }
      });
    }

    group('crafted zip64 sizes do not crash', () {
      // A zip64 extra field can declare a 64-bit compressed size. When it is
      // near the 64-bit maximum, the old bounds checks overflowed and either
      // built an out-of-range Uint8List over the tiny file (an uncatchable
      // crash on builds without a range check) or over-allocated. Reading an
      // entry must instead return at most the bytes actually present.
      Uint8List craft(int compressedSize) {
        final name = ascii.encode('a');
        final data = ascii.encode('x');
        final local = BytesBuilder();
        final lh = OutputMemoryStream()
          ..writeUint32(0x04034b50)
          ..writeUint16(20)
          ..writeUint16(0)
          ..writeUint16(0) // stored
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(data.length)
          ..writeUint32(1)
          ..writeUint16(name.length)
          ..writeUint16(0);
        local.add(lh.getBytes());
        local.add(name);
        local.add(data);
        final localBytes = local.takeBytes();

        final extra = OutputMemoryStream()
          ..writeUint16(1) // zip64 tag
          ..writeUint16(8)
          ..writeUint64(compressedSize);
        final extraBytes = extra.getBytes();

        final cd = OutputMemoryStream()
          ..writeUint32(0x02014b50)
          ..writeUint16(20)
          ..writeUint16(20)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(0xffffffff) // compressed size -> use zip64 extra
          ..writeUint32(1)
          ..writeUint16(name.length)
          ..writeUint16(extraBytes.length)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(0); // local header offset
        cd.writeBytes(name);
        cd.writeBytes(extraBytes);
        final cdBytes = cd.getBytes();

        final eocd = OutputMemoryStream()
          ..writeUint32(0x06054b50)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(1)
          ..writeUint16(1)
          ..writeUint32(cdBytes.length)
          ..writeUint32(localBytes.length)
          ..writeUint16(0);

        final out = BytesBuilder()
          ..add(localBytes)
          ..add(cdBytes)
          ..add(eocd.getBytes());
        return out.takeBytes();
      }

      for (final size in <int>[
        0x00000000ffffffff,
        0x0000800000000000,
        0x7fffffffffffffff,
        0x8000000000000000, // -2^63
        0xffffffffffffffff, // -1 as a signed 64-bit int
      ]) {
        test('0x${size.toRadixString(16)}', () {
          final bytes = craft(size);

          void check(Archive archive) {
            expect(archive.length, 1);
            final entry = archive.first;
            // No throw, and never more than the bytes in the file.
            final content = entry.readBytes();
            expect(content, isNotNull);
            expect(content!.length, lessThanOrEqualTo(bytes.length));
            // Reading every byte must stay in bounds.
            var sum = 0;
            for (final b in content) {
              sum += b;
            }
            expect(sum, greaterThanOrEqualTo(0));
          }

          // In-memory path.
          check(ZipDecoder().decodeBytes(bytes));

          // File-backed path.
          final dir = Directory.systemTemp.createTempSync('archive-zip64-');
          addTearDown(() => dir.deleteSync(recursive: true));
          final path = p.join(dir.path, 'evil.zip');
          File(path).writeAsBytesSync(bytes);
          final input = InputFileStream(path);
          check(ZipDecoder().decodeStream(input));
          input.closeSync();
        });
      }
    });

    group('malformed headers throw ArchiveException', () {
      // One stored entry 'a' holding 'x', with [extra] in its local header,
      // [flags] in both headers and [beforeEocd] just before the end record.
      Uint8List craft(
          {List<int> extra = const [],
          int flags = 0,
          List<int> beforeEocd = const []}) {
        final local = OutputMemoryStream()
          ..writeUint32(0x04034b50)
          ..writeUint16(20)
          ..writeUint16(flags)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(0)
          ..writeUint32(1)
          ..writeUint32(1)
          ..writeUint16(1)
          ..writeUint16(extra.length)
          ..writeBytes(ascii.encode('a'))
          ..writeBytes(extra)
          ..writeBytes(ascii.encode('x'));
        final localBytes = local.getBytes();
        final cd = OutputMemoryStream()
          ..writeUint32(0x02014b50)
          ..writeUint16(20)
          ..writeUint16(20)
          ..writeUint16(flags)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(0)
          ..writeUint32(1)
          ..writeUint32(1)
          ..writeUint16(1)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint32(0)
          ..writeUint32(0)
          ..writeBytes(ascii.encode('a'));
        final cdBytes = cd.getBytes();
        final eocd = OutputMemoryStream()
          ..writeUint32(0x06054b50)
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(1)
          ..writeUint16(1)
          ..writeUint32(cdBytes.length)
          ..writeUint32(localBytes.length)
          ..writeUint16(0);
        return Uint8List.fromList(
            [...localBytes, ...cdBytes, ...beforeEocd, ...eocd.getBytes()]);
      }

      test('an encrypted entry with an odd length extra field', () {
        // The search for an AES record read two bytes past the field.
        for (final length in [1, 3, 5, 7, 11]) {
          final bytes = craft(extra: List.filled(length, 0x11), flags: 0x1);
          expect(ZipDecoder().decodeBytes(bytes, password: 'x'), hasLength(1),
              reason: '$length');
        }
      });

      test('a zip64 locator pointing past the file', () {
        final locator = OutputMemoryStream()
          ..writeUint32(0x07064b50)
          ..writeUint32(0)
          ..writeUint64(0x7fffffffffff)
          ..writeUint32(1);
        final bytes = craft(beforeEocd: locator.getBytes());
        expect(() => ZipDecoder().decodeBytes(bytes),
            throwsA(isA<ArchiveException>()));
      });
    });
  });
}

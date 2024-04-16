import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_test_util.dart';

Future<void> extractArchiveToDisk(ArchiveDirectory archive, String root) async {
  for (final e in archive) {
    final path = '$root/${e.fullPathName}';
    if (e is ArchiveDirectory) {
      await Directory(path)
          .create(recursive: true);
      await extractArchiveToDisk(e, root);
    } else {
      final f = e as ArchiveFile;
      final output = OutputFileStream(path)
        ..open();
      f.writeContent(output);
      final bytes = f.readBytes();
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(0));
    }
  }
}

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

void main() {
  test('zip empty', () async {
    final archive = Archive();
    final encoded = ZipEncoder().encode(archive);
    final decoded = ZipDecoder().decodeBytes(encoded);
    expect(decoded.length, equals(0));
  });

  test('zip isFile', () async {
    var file = File(p.join('test/_data/zip/android-javadoc.zip'));
    var bytes = file.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final entries = archive.getAllEntries();
    expect(entries.length, equals(102));
  });

  test('file decode utf file', () {
    var bytes = File(p.join('test/_data/zip/utf.zip')).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final entries = archive.getAllEntries();
    expect(entries.length, equals(5));
  });

  test('file encoding zip file', () {
    final originalFileName = 'fileöäüÖÄÜß.txt';
    final bytes = Utf8Codec().encode('test');
    final archiveFile = ArchiveFile.bytes(originalFileName, bytes);
    final archive = Archive();
    archive.add(archiveFile);

    final encoder = ZipEncoder();
    final decoder = ZipDecoder();

    var encodedBytes = encoder.encode(archive)!;

    final archiveDecoded = decoder.decodeBytes(encodedBytes);

    final decodedFile = archiveDecoded[0];

    expect(decodedFile.name, originalFileName);
  });

  test('zip64', () {
    var bytes = File(p.join('test/_data/zip/zip64_archive.zip'))
        .readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    expect(archive.length, equals(3));
    expect(archive[0].size, equals(3136));
  });

  test('zip data types', () {
    final archive = Archive();
    archive.add(ArchiveFile.bytes('uint8list', Uint8List(2)));
    archive.add(ArchiveFile.bytes('list_int', Uint8List.fromList([1, 2])));
    archive.add(
        ArchiveFile.typedData('float32list', Float32List.fromList([3.0, 4.0])));
    archive.add(ArchiveFile.string('string', 'hello'));
    final zipData = ZipEncoder().encode(archive);

    final archive2 = ZipDecoder().decodeBytes(zipData!);
    expect(archive2.length, equals(archive.length));
  });

  test('encode', () {
    final archive = Archive();
    final bdata = 'hello world';
    final bytes = Uint8List.fromList(bdata.codeUnits);
    final name = 'abc.txt';
    final afile = ArchiveFile.bytes(name, bytes);
    archive.add(afile);

    final zipData = ZipEncoder().encode(archive);

    File(p.join(testOutputPath, 'uncompressed.zip'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(zipData);

    final arc = ZipDecoder().decodeBytes(zipData, verify: true);
    expect(arc.length, equals(1));
    final arcData = arc[0].getContent()!.toUint8List();
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

    var zipData = ZipEncoder()
        .encode(archive, modified: DateTime.utc(2010, DateTime.january, 1))!;

    File(p.join(testOutputPath, 'uncompressed.zip'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(zipData);

    var arc = ZipDecoder().decodeBytes(zipData, verify: true);
    expect(arc.length, equals(1));
    var arcData = arc[0].getContent()!.toUint8List();
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
      var content = archive[i].getContent()!.toUint8List();
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
    final file = File(p.join('test/_data/zip/aes256.zip'));
    final fileBytes = file.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(fileBytes, password: '12345');

    expect(archive.length, equals(2));
    for (var i = 0; i < archive.length; ++i) {
      final file = File(p.join('test/_data/zip/${archive[i].name}'));
      final bytes = file.readAsBytesSync();
      final content = archive[i].getContent()!.toUint8List();
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
      final zBytes = archive[i].getContent()!.toUint8List();
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

  test('encode password', () {
    final archive = Archive();
    final bdata = 'hello world';
    final bytes = Uint8List.fromList(bdata.codeUnits);
    final name = 'abc.txt';
    final afile = ArchiveFile.bytes(name, bytes);
    archive.add(afile);

    final zipData = ZipEncoder(password: 'abc123').encode(archive)!;

    File(p.join(testOutputPath, 'zip_password.zip'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(zipData);

    final arc = ZipDecoder().decodeBytes(zipData, password: 'abc123');
    expect(arc.length, equals(1));
    final arcData = arc[0].getContent()!.toUint8List();
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
      final zBytes = archive[i].getContent()!.toUint8List();
      if (archive[i].name == 'a.txt') {
        compareBytes(zBytes, aBytes);
      } else if (archive[i].name == 'cat.jpg') {
        compareBytes(zBytes, bBytes);
      } else {
        throw TestFailure('Invalid file found');
      }
    }

    // Encode the archive we just decoded
    final zipped = ZipEncoder().encode(archive)!;

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

  test('decode', () async {
    final archive = ZipDecoder().decodeStream(
        InputMemoryStream(File('test/_data/zip/android-javadoc.zip').readAsBytesSync()));

    await extractArchiveToDisk(archive, '$testOutputPath/android-javadoc');
  });

  test('symlink', () async {
    final stream = InputMemoryStream(File('test/_data/zip/symlink.zip').readAsBytesSync());
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
      final f = file as ArchiveFile;
      final String filename = f.name;
      final data = f.getContent();
      await f.clear();
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
}

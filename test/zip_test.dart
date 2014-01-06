part of archive_test;

var zipTests = [
  {
    'Name':    "res/zip/test.zip",
    'Comment': "This is a zipfile comment.",
    'File': [
      {
        'Name':    "test.txt",
        'Content': "This is a test text file.\n".codeUnits,
        'Mtime':   "09-05-10 12:12:02",
        'Mode':    0644,
      },
      {
        'Name':  "gophercolor16x16.png",
        'File':  "gophercolor16x16.png",
        'Mtime': "09-05-10 15:52:58",
        'Mode':  0644,
      },
    ],
  },
  {
    'Name':    "res/zip/test-trailing-junk.zip",
    'Comment': "This is a zipfile comment.",
    'File': [
      {
        'Name':    "test.txt",
        'Content': "This is a test text file.\n".codeUnits,
        'Mtime':   "09-05-10 12:12:02",
        'Mode':    0644,
      },
      {
        'Name':  "gophercolor16x16.png",
        'File':  "gophercolor16x16.png",
        'Mtime': "09-05-10 15:52:58",
        'Mode':  0644,
      },
    ],
  },
  /*{
    'Name':   "res/zip/r.zip",
    'Source': returnRecursiveZip,
    'File': [
      {
        'Name':    "r/r.zip",
        'Content': rZipBytes(),
        'Mtime':   "03-04-10 00:24:16",
        'Mode':    0666,
      },
    ],
  },*/
  {
    'Name': "res/zip/symlink.zip",
    'File': [
      {
        'Name':    "symlink",
        'Content': "../target".codeUnits,
        //'Mode':    0777 | os.ModeSymlink,
      },
    ],
  },
  {
    'Name': "res/zip/readme.zip",
  },
  {
    'Name':  "res/zip/readme.notzip",
    //'Error': ErrFormat,
  },
  {
    'Name': "res/zip/dd.zip",
    'File': [
      {
        'Name':    "filename",
        'Content': "This is a test textfile.\n".codeUnits,
        'Mtime':   "02-02-11 13:06:20",
        'Mode':    0666,
      },
    ],
  },
  /*{
    // created in windows XP file manager.
    'Name': "res/zip/winxp.zip",
    'File': crossPlatform,
  },
  {
    // created by Zip 3.0 under Linux
    'Name': "res/zip/unix.zip",
    'File': crossPlatform,
  },*/
  {
    'Name': "res/zip/go-no-datadesc-sig.zip",
    'File': [
      {
        'Name':    "foo.txt",
        'Content': "foo\n".codeUnits,
        'Mtime':   "03-08-12 16:59:10",
        'Mode':    0644,
      },
      {
        'Name':    "bar.txt",
        'Content': "bar\n".codeUnits,
        'Mtime':   "03-08-12 16:59:12",
        'Mode':    0644,
      },
    ],
  },
  {
    'Name': "res/zip/go-with-datadesc-sig.zip",
    'File': [
      {
        'Name':    "foo.txt",
        'Content': "foo\n".codeUnits,
        'Mode':    0666,
      },
      {
        'Name':    "bar.txt",
        'Content': "bar\n".codeUnits,
        'Mode':    0666,
      },
    ],
  },
  /*{
    'Name':   "Bad-CRC32-in-data-descriptor",
    'Source': returnCorruptCRC32Zip,
    'File': [
      {
        'Name':       "foo.txt",
        'Content':    "foo\n".codeUnits,
        'Mode':       0666,
        'ContentErr': ErrChecksum,
      },
      {
        'Name':    "bar.txt",
        'Content': "bar\n".codeUnits,
        'Mode':    0666,
      },
    ],
  },*/
  // Tests that we verify (and accept valid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name': "res/zip/crc32-not-streamed.zip",
    'File': [
      {
        'Name':    "foo.txt",
        'Content': "foo\n".codeUnits,
        'Mtime':   "03-08-12 16:59:10",
        'Mode':    0644,
      },
      {
        'Name':    "bar.txt",
        'Content': "bar\n".codeUnits,
        'Mtime':   "03-08-12 16:59:12",
        'Mode':    0644,
      },
    ],
  },
  // Tests that we verify (and reject invalid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name':   "res/zip/crc32-not-streamed.zip",
    //'Source': returnCorruptNotStreamedZip,
    'File': [
      {
        'Name':       "foo.txt",
        'Content':    "foo\n".codeUnits,
        'Mtime':      "03-08-12 16:59:10",
        'Mode':       0644,
        'VerifyChecksum': true
        //'ContentErr': ErrChecksum,
      },
      {
        'Name':    "bar.txt",
        'Content': "bar\n".codeUnits,
        'Mtime':   "03-08-12 16:59:12",
        'Mode':    0644,
        'VerifyChecksum': true
      },
    ],
  },
  {
    'Name': "res/zip/zip64.zip",
    'File': [
      {
        'Name':    "README",
        'Content': "This small file is in ZIP64 format.\n".codeUnits,
        'Mtime':   "08-10-12 14:33:32",
        'Mode':    0644,
      },
    ],
  },
];

void defineZipTests() {
  group('zip', () {
    ZipDecoder zipDecoder = new ZipDecoder();
    ZipEncoder zipEncoder = new ZipEncoder();

    test('decode/encode', () {
      var file = new Io.File('res/test.zip');
      var bytes = file.readAsBytesSync();

      Archive archive = zipDecoder.decodeBytes(bytes);
      expect(archive.numberOfFiles(), equals(2));

      var b = new Io.File('res/cat.jpg');
      List<int> b_bytes = b.readAsBytesSync();
      List<int> a_bytes = a_txt.codeUnits;

      for (int i = 0; i < archive.numberOfFiles(); ++i) {
        List<int> z_bytes = archive.fileData(i);
        if (archive.fileName(i) == 'a.txt') {
          compare_bytes(z_bytes, a_bytes);
        } else if (archive.fileName(i) == 'cat.jpg') {
          compare_bytes(z_bytes, b_bytes);
        } else {
          throw new TestFailure('Invalid file found');
        }
      }

      // Encode the archive we just decoded
      List<int> zipped = zipEncoder.encode(archive);

      Io.File f = new Io.File('out/test.zip');
      f.createSync(recursive: true);
      f.writeAsBytesSync(zipped);

      // Decode the archive we just encoded
      Archive archive2 = zipDecoder.decodeBytes(zipped);

      expect(archive2.numberOfFiles(), equals(archive.numberOfFiles()));
      for (int i = 0; i < archive2.numberOfFiles(); ++i) {
        expect(archive2.fileName(i), equals(archive.fileName(i)));
        expect(archive2.fileSize(i), equals(archive.fileSize(i)));
      }
    });

    for (Map z in zipTests) {
      test('unzip ${z['Name']}', () {
        var file = new Io.File(z['Name']);
        var bytes = file.readAsBytesSync();

        Archive archive = zipDecoder.decodeBytes(bytes);
        List<ZipFileHeader> zipFiles = zipDecoder.directory.fileHeaders;

        if (z.containsKey('Comment')) {
          expect(zipDecoder.directory.zipFileComment, z['Comment']);
        }

        if (!z.containsKey('File')) {
          return;
        }
        expect(zipFiles.length, equals(z['File'].length));


        for (int i = 0; i < zipFiles.length; ++i) {
          ZipFileHeader zipFileHeader = zipFiles[i];
          ZipFile zipFile = zipFileHeader.file;

          var hdr = z['File'][i];

          if (hdr.containsKey('Name')) {
            expect(zipFile.filename, equals(hdr['Name']));
          }
          if (hdr.containsKey('Content')) {
            expect(zipFile.content, equals(hdr['Content']));
          }
          if (hdr.containsKey('VerifyChecksum')) {
            expect(zipFile.verifyCrc32(), equals(hdr['VerifyChecksum']));
          }
        }
      });
    }
  });
}

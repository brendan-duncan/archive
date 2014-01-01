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
    ZipArchive zip = new ZipArchive();

    getCrc32([]);

    for (Map z in zipTests) {
      test('unzip ${z['Name']}', () {
        var file = new Io.File(z['Name']);
        file.openSync();
        var bytes = file.readAsBytesSync();

        Archive archive = zip.decode(bytes);
        List<ZipFileHeader> zipFiles = zip.directory.fileHeaders;

        if (z.containsKey('Comment')) {
          expect(zip.directory.zipFileComment, z['Comment']);
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

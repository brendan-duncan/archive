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
  /*{
    Name:    "test-trailing-junk.zip",
    Comment: "This is a zipfile comment.",
    File: []ZipTestFile{
      {
        Name:    "test.txt",
        Content: []byte("This is a test text file.\n"),
        Mtime:   "09-05-10 12:12:02",
        Mode:    0644,
      },
      {
        Name:  "gophercolor16x16.png",
        File:  "gophercolor16x16.png",
        Mtime: "09-05-10 15:52:58",
        Mode:  0644,
      },
    },
  },
  {
    Name:   "r.zip",
    Source: returnRecursiveZip,
    File: []ZipTestFile{
      {
        Name:    "r/r.zip",
        Content: rZipBytes(),
        Mtime:   "03-04-10 00:24:16",
        Mode:    0666,
      },
    },
  },
  {
    Name: "symlink.zip",
    File: []ZipTestFile{
      {
        Name:    "symlink",
        Content: []byte("../target"),
        Mode:    0777 | os.ModeSymlink,
      },
    },
  },
  {
    Name: "readme.zip",
  },
  {
    Name:  "readme.notzip",
    Error: ErrFormat,
  },
  {
    Name: "dd.zip",
    File: []ZipTestFile{
      {
        Name:    "filename",
        Content: []byte("This is a test textfile.\n"),
        Mtime:   "02-02-11 13:06:20",
        Mode:    0666,
      },
    },
  },
  {
    // created in windows XP file manager.
    Name: "winxp.zip",
    File: crossPlatform,
  },
  {
    // created by Zip 3.0 under Linux
    Name: "unix.zip",
    File: crossPlatform,
  },
  {
    // created by Go, before we wrote the "optional" data
    // descriptor signatures (which are required by OS X)
    Name: "go-no-datadesc-sig.zip",
    File: []ZipTestFile{
      {
        Name:    "foo.txt",
        Content: []byte("foo\n"),
        Mtime:   "03-08-12 16:59:10",
        Mode:    0644,
      },
      {
        Name:    "bar.txt",
        Content: []byte("bar\n"),
        Mtime:   "03-08-12 16:59:12",
        Mode:    0644,
      },
    },
  },
  {
    // created by Go, after we wrote the "optional" data
    // descriptor signatures (which are required by OS X)
    Name: "go-with-datadesc-sig.zip",
    File: []ZipTestFile{
      {
        Name:    "foo.txt",
        Content: []byte("foo\n"),
        Mode:    0666,
      },
      {
        Name:    "bar.txt",
        Content: []byte("bar\n"),
        Mode:    0666,
      },
    },
  },
  {
    Name:   "Bad-CRC32-in-data-descriptor",
    Source: returnCorruptCRC32Zip,
    File: []ZipTestFile{
      {
        Name:       "foo.txt",
        Content:    []byte("foo\n"),
        Mode:       0666,
        ContentErr: ErrChecksum,
      },
      {
        Name:    "bar.txt",
        Content: []byte("bar\n"),
        Mode:    0666,
      },
    },
  },
  // Tests that we verify (and accept valid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    Name: "crc32-not-streamed.zip",
    File: []ZipTestFile{
      {
        Name:    "foo.txt",
        Content: []byte("foo\n"),
        Mtime:   "03-08-12 16:59:10",
        Mode:    0644,
      },
      {
        Name:    "bar.txt",
        Content: []byte("bar\n"),
        Mtime:   "03-08-12 16:59:12",
        Mode:    0644,
      },
    },
  },
  // Tests that we verify (and reject invalid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    Name:   "crc32-not-streamed.zip",
    Source: returnCorruptNotStreamedZip,
    File: []ZipTestFile{
      {
        Name:       "foo.txt",
        Content:    []byte("foo\n"),
        Mtime:      "03-08-12 16:59:10",
        Mode:       0644,
        ContentErr: ErrChecksum,
      },
      {
        Name:    "bar.txt",
        Content: []byte("bar\n"),
        Mtime:   "03-08-12 16:59:12",
        Mode:    0644,
      },
    },
  },
  {
    Name: "zip64.zip",
    File: []ZipTestFile{
      {
        Name:    "README",
        Content: []byte("This small file is in ZIP64 format.\n"),
        Mtime:   "08-10-12 14:33:32",
        Mode:    0644,
      },
    },
  },*/
];

void defineZipTests() {
  group('zip', () {
    ZipArchive zip = new ZipArchive();

    for (Map z in zipTests) {
      test('unzip ${z['Name']}', () {
        var file = new Io.File(z['Name']);
        file.openSync();
        var bytes = file.readAsBytesSync();

        Archive archive = zip.decode(bytes);
        List<ZipFileHeader> zipFiles = zip.directory.fileHeaders;

        expect(zipFiles.length, equals(z['File'].length));

        if (z.containsKey('Comment')) {
          expect(zip.directory.zipFileComment, z['Comment']);
        }

        for (int i = 0; i < zipFiles.length; ++i) {
          ZipFileHeader zipFileHeader = zipFiles[i];
          ZipFile zipFile = zipFileHeader.file;

          var hdr = z['File'][i];

          if (hdr.containsKey('Name')) {
            expect(zipFile.filename, equals(hdr['Name']));
          }

          if (hdr.containsKey('Mode')) {
            //expect(zipFileHeader.internalFileAttributes, equals(hdr['Mode']));
          }
        }
      });
    }
  });
}

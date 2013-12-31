part of archive_test;

var tarTests = [
  {
    'file': 'res/tar/gnu.tar',
    'headers': [
      {
        'Name':     "small.txt",
        'Mode':     0640,
        'Uid':      73025,
        'Gid':      5000,
        'Size':     5,
        'ModTime':  1244428340,
        'Typeflag': '0',
        'Uname':    "dsymonds",
        'Gname':    "eng",
      },
      {
        'Name':     "small2.txt",
        'Mode':     0640,
        'Uid':      73025,
        'Gid':      5000,
        'Size':     11,
        'ModTime':  1244436044,
        'Typeflag': '0',
        'Uname':    "dsymonds",
        'Gname':    "eng",
      }],
    'cksums': [
      "e38b27eaccb4391bdec553a7f3ae6b2f",
      "c65bd2e50a56a2138bf1716f2fd56fe9",
    ],
  },
  {
    'file': "res/tar/star.tar",
    'headers': [
      {
        'Name':       "small.txt",
        'Mode':       0640,
        'Uid':        73025,
        'Gid':        5000,
        'Size':       5,
        'ModTime':    1244592783,
        'Typeflag':   '0',
        'Uname':      "dsymonds",
        'Gname':      "eng",
        'AccessTime': 1244592783,
        'ChangeTime': 1244592783,
      },
      {
        'Name':       "small2.txt",
        'Mode':       0640,
        'Uid':        73025,
        'Gid':        5000,
        'Size':       11,
        'ModTime':    1244592783,
        'Typeflag':   '0',
        'Uname':      "dsymonds",
        'Gname':      "eng",
        'AccessTime': 1244592783,
        'ChangeTime': 1244592783,
      },
    ],
  },
  {
    'file': "res/tar/v7.tar",
    'headers': [
      {
        'Name':     "small.txt",
        'Mode':     0444,
        'Uid':      73025,
        'Gid':      5000,
        'Size':     5,
        'ModTime':  1244593104,
        'Typeflag': '',
      },
      {
        'Name':     "small2.txt",
        'Mode':     0444,
        'Uid':      73025,
        'Gid':      5000,
        'Size':     11,
        'ModTime':  1244593104,
        'Typeflag': '',
      },
    ],
  },
  /*{
    'file': "res/tar/pax.tar",
    'headers': [
      {
        'Name':       "a/123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100",
        'Mode':       0664,
        'Uid':        1000,
        'Gid':        1000,
        'Uname':      "shane",
        'Gname':      "shane",
        'Size':       7,
        'ModTime':    1350244992,
        'ChangeTime': 1350244992,
        'AccessTime': 1350244992,
        'Typeflag':   TarFile.TYPE_NORMAL_FILE,
      },
      {
        'Name':       "a/b",
        'Mode':       0777,
        'Uid':        1000,
        'Gid':        1000,
        'Uname':      "shane",
        'Gname':      "shane",
        'Size':       0,
        'ModTime':    1350266320,
        'ChangeTime': 1350266320,
        'AccessTime': 1350266320,
        'Typeflag':   TarFile.TYPE_SYMBOLIC_LINK,
        'Linkname':   "123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100",
      },
    ],
  },*/
  {
    'file': "res/tar/nil-uid.tar",
    'headers': [
      {
        'Name':     "P1050238.JPG.log",
        'Mode':     0664,
        'Uid':      0,
        'Gid':      0,
        'Size':     14,
        'ModTime':  1365454838,
        'Typeflag': TarFile.TYPE_NORMAL_FILE,
        'Linkname': "",
        'Uname':    "eyefi",
        'Gname':    "eyefi",
        'Devmajor': 0,
        'Devminor': 0,
      },
    ],
  },
];

void tar_test() {
  TarArchive tar = new TarArchive();

  for (Map t in tarTests) {
    test('untar ${t['file']}', () {
      var file = new Io.File(t['file']);
      file.openSync();
      var bytes = file.readAsBytesSync();

      Archive archive = tar.decode(bytes);
      expect(tar.files.length, equals(t['headers'].length));

      for (int i = 0; i < tar.files.length; ++i) {
        TarFile file = tar.files[i];
        var hdr = t['headers'][i];

        if (hdr.containsKey('Name')) {
          expect(file.filename, equals(hdr['Name']));
        }
        if (hdr.containsKey('Mode')) {
          expect(file.mode, equals(hdr['Mode']));
        }
        if (hdr.containsKey('Uid')) {
          expect(file.ownerId, equals(hdr['Uid']));
        }
        if (hdr.containsKey('Gid')) {
          expect(file.groupId, equals(hdr['Gid']));
        }
        if (hdr.containsKey('Size')) {
          expect(file.fileSize, equals(hdr['Size']));
        }
        if (hdr.containsKey('ModTime')) {
          expect(file.lastModTime, equals(hdr['ModTime']));
        }
        if (hdr.containsKey('Typeflag')) {
          expect(file.typeFlag, equals(hdr['Typeflag']));
        }
        if (hdr.containsKey('Uname')) {
          expect(file.ownerUserName, equals(hdr['Uname']));
        }
        if (hdr.containsKey('Gname')) {
          expect(file.ownerGroupName, equals(hdr['Gname']));
        }
      }
    });
  }
}

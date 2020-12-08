import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_utils.dart';

var tarTests = [
  {
    'file': 'res/tar/gnu.tar',
    'headers': [
      {
        'Name': 'small.txt',
        'Mode': int.parse('0640', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 5,
        'ModTime': 1244428340,
        'Typeflag': '0',
        'Uname': 'dsymonds',
        'Gname': 'eng',
      },
      {
        'Name': 'small2.txt',
        'Mode': int.parse('0640', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 11,
        'ModTime': 1244436044,
        'Typeflag': '0',
        'Uname': 'dsymonds',
        'Gname': 'eng',
      }
    ],
    'cksums': [
      'e38b27eaccb4391bdec553a7f3ae6b2f',
      'c65bd2e50a56a2138bf1716f2fd56fe9',
    ],
  },
  {
    'file': 'res/tar/star.tar',
    'headers': [
      {
        'Name': 'small.txt',
        'Mode': int.parse('0640', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 5,
        'ModTime': 1244592783,
        'Typeflag': '0',
        'Uname': 'dsymonds',
        'Gname': 'eng',
        'AccessTime': 1244592783,
        'ChangeTime': 1244592783,
      },
      {
        'Name': 'small2.txt',
        'Mode': int.parse('0640', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 11,
        'ModTime': 1244592783,
        'Typeflag': '0',
        'Uname': 'dsymonds',
        'Gname': 'eng',
        'AccessTime': 1244592783,
        'ChangeTime': 1244592783,
      },
    ],
  },
  {
    'file': 'res/tar/v7.tar',
    'headers': [
      {
        'Name': 'small.txt',
        'Mode': int.parse('0444', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 5,
        'ModTime': 1244593104,
        'Typeflag': '',
      },
      {
        'Name': 'small2.txt',
        'Mode': int.parse('0444', radix: 8),
        'Uid': 73025,
        'Gid': 5000,
        'Size': 11,
        'ModTime': 1244593104,
        'Typeflag': '',
      },
    ],
  },
  /*{
    'file': 'res/tar/pax.tar',
    'headers': [
      {
        'Name':       'a/123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100',
        'Mode':       int.parse('0664',radix: 8),
        'Uid':        1000,
        'Gid':        1000,
        'Uname':      'shane',
        'Gname':      'shane',
        'Size':       7,
        'ModTime':    1350244992,
        'ChangeTime': 1350244992,
        'AccessTime': 1350244992,
        'Typeflag':   TarFile.TYPE_NORMAL_FILE,
      },
      {
        'Name':       'a/b',
        'Mode':       int.parse('0777',radix: 8),
        'Uid':        1000,
        'Gid':        1000,
        'Uname':      'shane',
        'Gname':      'shane',
        'Size':       0,
        'ModTime':    1350266320,
        'ChangeTime': 1350266320,
        'AccessTime': 1350266320,
        'Typeflag':   TarFile.TYPE_SYMBOLIC_LINK,
        'Linkname':   '123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100',
      },
    ],
  },*/
  {
    'file': 'res/tar/nil-uid.tar',
    'headers': [
      {
        'Name': 'P1050238.JPG.log',
        'Mode': int.parse('0664', radix: 8),
        'Uid': 0,
        'Gid': 0,
        'Size': 14,
        'ModTime': 1365454838,
        'Typeflag': TarFile.TYPE_NORMAL_FILE,
        'Linkname': '',
        'Uname': 'eyefi',
        'Gname': 'eyefi',
        'Devmajor': 0,
        'Devminor': 0,
      },
    ],
  },
];

void main() {
  final tar = TarDecoder();
  final tarEncoder = TarEncoder();

  test('tar invalid archive', () {
    try {
      TarDecoder().decodeBytes([1, 2, 3]);
      assert(false);
    } catch (e) {
      // pass
    }
  });

  test('tar file', () {
    TarEncoder().encode(Archive()..addFile(ArchiveFile('file.txt', 1, [100])));
  });

  test('long file name', () {
    final file = File(p.join(testDirPath, 'res/tar/x.tar'));
    final bytes = file.readAsBytesSync();
    final archive = tar.decodeBytes(bytes, verify: true);

    expect(archive.numberOfFiles(), equals(1));
    var x = '';
    for (var i = 0; i < 150; ++i) {
      x += 'x';
    }
    x += '.txt';
    expect(archive.files[0].name, equals(x));
  });

  test('symlink', () {
    var file = File(p.join(testDirPath, 'res/tar/symlink_tar.tar'));
    List<int> bytes = file.readAsBytesSync();
    final archive = tar.decodeBytes(bytes, verify: true);
    expect(archive.numberOfFiles(), equals(4));
    expect(archive.files[1].isSymbolicLink, equals(true));
    expect(archive.files[1].nameOfLinkedFile, equals('b/b.txt'));
  });

  test('decode test2.tar', () {
    var file = File(p.join(testDirPath, 'res/test2.tar'));
    List<int> bytes = file.readAsBytesSync();
    final archive = tar.decodeBytes(bytes, verify: true);

    final expected_files = <File>[];
    ListDir(expected_files, Directory(p.join(testDirPath, 'res/test2')));

    expect(archive.length, equals(4));
  });

  test('decode test2.tar.gz', () {
    var file = File(p.join(testDirPath, 'res/test2.tar.gz'));
    List<int> bytes = file.readAsBytesSync();

    bytes = GZipDecoder().decodeBytes(bytes, verify: true);
    final archive = tar.decodeBytes(bytes, verify: true);

    final expected_files = <File>[];
    ListDir(expected_files, Directory(p.join(testDirPath, 'res/test2')));

    expect(archive.length, equals(4));
  });

  test('decode/encode', () {
    final a_bytes = a_txt.codeUnits;

    var b = File(p.join(testDirPath, 'res/cat.jpg'));
    List<int> b_bytes = b.readAsBytesSync();

    var file = File(p.join(testDirPath, 'res/test.tar'));
    List<int> bytes = file.readAsBytesSync();

    final archive = tar.decodeBytes(bytes, verify: true);
    expect(archive.numberOfFiles(), equals(2));

    var t_file = archive.fileName(0);
    expect(t_file, equals('a.txt'));
    var t_bytes = archive.fileData(0);
    compare_bytes(t_bytes, a_bytes);

    t_file = archive.fileName(1);
    expect(t_file, equals('cat.jpg'));
    t_bytes = archive.fileData(1);
    compare_bytes(t_bytes, b_bytes);

    final encoded = tarEncoder.encode(archive);
    final out = File(p.join(testDirPath, 'out/test.tar'));
    out.createSync(recursive: true);
    out.writeAsBytesSync(encoded);

    // Test round-trip
    final archive2 = tar.decodeBytes(encoded, verify: true);
    expect(archive2.numberOfFiles(), equals(2));

    t_file = archive2.fileName(0);
    expect(t_file, equals('a.txt'));
    t_bytes = archive2.fileData(0);
    compare_bytes(t_bytes, a_bytes);

    t_file = archive2.fileName(1);
    expect(t_file, equals('cat.jpg'));
    t_bytes = archive2.fileData(1);
    compare_bytes(t_bytes, b_bytes);
  });

  for (Map<String, dynamic> t in tarTests) {
    test('untar ${t['file']}', () {
      var file = File(p.join(testDirPath, t['file'] as String));
      var bytes = file.readAsBytesSync();

      /*Archive archive =*/ tar.decodeBytes(bytes, verify: true);
      expect(tar.files.length, equals(t['headers'].length));

      for (var i = 0; i < tar.files.length; ++i) {
        final file = tar.files[i];
        var hdr = t['headers'][i] as Map<String, dynamic>;

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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_test_util.dart';

// The name stored in a pax header in _data/tar/pax.tar, too long for the
// 100 byte name field.
const _paxLongName = '123456789101112131415161718192021222324252627282930'
    '313233343536373839404142434445464748495051525354555657585960616263646566'
    '6768697071727374757677787980818283848586878889909192939495969798991'
    '00';

var tarTests = [
  {
    'file': '_data/tar/gnu.tar',
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
    'file': '_data/tar/star.tar',
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
    'file': '_data/tar/v7.tar',
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
  {
    'file': '_data/tar/pax.tar',
    'headers': [
      {
        'Name':
            'a/123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100',
        'Mode': int.parse('0664', radix: 8),
        'Uid': 1000,
        'Gid': 1000,
        'Uname': 'shane',
        'Gname': 'shane',
        'Size': 7,
        'ModTime': 1350244992,
        'ChangeTime': 1350244992,
        'AccessTime': 1350244992,
        'Typeflag': TarFile.normalFile,
      },
      {
        'Name': 'a/b',
        'Mode': int.parse('0777', radix: 8),
        'Uid': 1000,
        'Gid': 1000,
        'Uname': 'shane',
        'Gname': 'shane',
        'Size': 0,
        'ModTime': 1350266320,
        'ChangeTime': 1350266320,
        'AccessTime': 1350266320,
        'Typeflag': TarFile.symbolicLink,
        'Linkname':
            '123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100',
      },
    ],
  },
  {
    'file': '_data/tar/nil-uid.tar',
    'headers': [
      {
        'Name': 'P1050238.JPG.log',
        'Mode': int.parse('0664', radix: 8),
        'Uid': 0,
        'Gid': 0,
        'Size': 14,
        'ModTime': 1365454838,
        'Typeflag': TarFile.normalFile,
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
  group('tar', () {
    test('invalid archive', () {
      try {
        TarDecoder().decodeBytes(Uint8List.fromList([1, 2, 3]));
        assert(false);
      } catch (e) {
        // pass
      }
    });

    test('file', () {
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes('file.txt', [100])));
      File(p.join(testOutputPath, 'tar_encoded.tar'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tar);
    });

    test('file with symlink', () {
      ArchiveFile symlink = ArchiveFile.symlink('file.txt', 'file2.txt');
      final tar = TarEncoder().encodeBytes(Archive()..add(symlink));
      File(p.join(testOutputPath, 'tar_encoded.tar'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tar);
      final archive = TarDecoder().decodeBytes(tar);
      expect(archive[0].isSymbolicLink, true);
    });

    test('file GNU tar files store extra long file names in a separate file.',
        () {
      var longFileName =
          'GNU tar files store extra long file names in a separate file. gt100 gt100 gt100 gt100 gt100 gt100 gt100.txt';
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes(longFileName, [100])));

      File(p.join(testOutputPath, 'tar_encoded.tar'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tar);

      final tarDecoded = TarDecoder().decodeBytes(tar);
      expect(tarDecoded.length, 1);
      expect(tarDecoded[0].name, longFileName);
    });

    test('long file name', () {
      final file = File('test/_data/tar/x.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);

      expect(archive.length, equals(1));
      var x = '';
      for (var i = 0; i < 150; ++i) {
        x += 'x';
      }
      x += '.txt';
      expect(archive[0].name, equals(x));
    });

    test('pax header with binary xattr record', () {
      // Vendor extensions like SCHILY.xattr store raw binary values, which
      // can contain invalid UTF-8 and embedded newlines. Those must not
      // prevent the records around them, like 'path', from being read.
      final file = File('test/_data/tar/pax_binary_xattr.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);

      expect(archive.length, equals(1));
      expect(archive[0].name, equals('pax/${'p' * 120}.txt'));
      expect(archive[0].readBytes(), equals(utf8.encode('hello pax\n')));
      // The name comes from the record after the binary one, the time from
      // the record before it.
      expect(archive[0].lastModTime, equals(1788382072));
    });

    test('GNU long link name', () {
      // GNU writes both a long name and a long link target as an entry called
      // '././@LongLink', and only the type flag says which one it is: 'L' for
      // the name, 'K' for the link target.
      final file = File('test/_data/tar/gnu_longlink.tar');
      final archive = TarDecoder()
          .decodeBytes(file.readAsBytesSync(), verify: true, storeData: false);

      final link = archive.files.firstWhere((f) => f.name.contains('ln_'));
      expect(link.name.length, equals(149));
      // 164 bytes, well past the 100 byte field it would otherwise be cut to.
      expect(link.symbolicLink, equals('${'n' * 160}.txt'));
    });

    test('verify rejects what is not a tar', () {
      // Without a checksum check nothing tells a tar apart from an unrelated
      // file: every other header field reads as something.
      final zip = File('test/_data/tar/folder.zip').readAsBytesSync();
      expect(() => TarDecoder().decodeBytes(zip, verify: true),
          throwsA(isA<ArchiveException>()));

      // Every archive the tests carry has to still pass.
      for (final path in Directory('test/_data/tar')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tar'))) {
        expect(
            () =>
                TarDecoder().decodeBytes(path.readAsBytesSync(), verify: true),
            returnsNormally,
            reason: path.path);
      }
    });

    test('pax header size, mtime, uid and gid records', () {
      // A pax 'size' record overrides the entry's own header field, which is
      // left at 0 in this archive. Missing it doesn't just lose the size, it
      // makes the file's content be read as the next entry's header.
      final file = File('test/_data/tar/pax_size.tar');
      final archive = TarDecoder().decodeBytes(file.readAsBytesSync());

      expect(archive.length, equals(1));
      expect(archive[0].name, equals('f.txt'));
      expect(archive[0].size, equals(14));
      expect(archive[0].readBytes(), equals(utf8.encode('pax size wins\n')));
      expect(archive[0].lastModTime, equals(1600000000));
      expect(archive[0].ownerId, equals(4242));
      expect(archive[0].groupId, equals(1717));
    });

    test('pax size record survives a second metadata header', () {
      // The record describes the entry it precedes, not the pax header that
      // happens to sit in between. Applying it there reads the wrong number of
      // bytes out of that header and leaves the stream inside it, so the file's
      // own content ends up being parsed as an entry.
      Uint8List header(String name, int size, String typeFlag) {
        final h = Uint8List(512);
        void put(int off, String s) =>
            h.setRange(off, off + s.length, ascii.encode(s));
        put(0, name);
        put(100, '0000644');
        put(108, '0000000');
        put(116, '0000000');
        put(124, size.toRadixString(8).padLeft(11, '0'));
        put(136, '00000000000');
        put(148, '        ');
        put(156, typeFlag);
        put(257, 'ustar');
        put(263, '00');
        var sum = 0;
        for (final b in h) {
          sum += b;
        }
        put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
        return h;
      }

      List<int> block(List<int> data) =>
          [...data, ...Uint8List((512 - data.length % 512) % 512)];

      List<int> record(String keyword, String value) {
        for (var length = keyword.length + value.length + 3;; length++) {
          if ('$length'.length + keyword.length + value.length + 3 == length) {
            return ascii.encode('$length $keyword=$value\n');
          }
        }
      }

      final content = ascii.encode('HELLO WORLD, 21 BYTES');
      final size = record('size', '${content.length}');
      final path = record('path', 'renamed_by_pax.txt');
      final bytes = Uint8List.fromList([
        ...header('PaxHeader/size', size.length, TarFile.exHeader),
        ...block(size),
        ...header('PaxHeader/path', path.length, TarFile.exHeader),
        ...block(path),
        ...header('original.txt', 0, TarFile.normalFile),
        ...block(content),
        ...Uint8List(1024),
      ]);

      final archive = TarDecoder().decodeBytes(bytes);
      expect(archive.length, equals(1));
      expect(archive[0].name, equals('renamed_by_pax.txt'));
      expect(archive[0].size, equals(content.length));
      expect(archive[0].readBytes(), equals(content));
    });

    test('pax header without storing data', () {
      // The pax header's own content has to be read even when file data is
      // being skipped, since it carries the next entry's name.
      final file = File('test/_data/tar/pax.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, storeData: false);

      expect(archive.length, equals(2));
      expect(archive[0].name, equals('a/${_paxLongName}'));
      expect(archive[1].symbolicLink, equals(_paxLongName));
    });

    test('base 256 encoded header fields', () {
      // GNU tar encodes values too large for the octal field in base 256.
      final decoder = TarDecoder();
      final archive = decoder.decodeBytes(
          File('test/_data/tar/base256_size.tar').readAsBytesSync());
      expect(archive.length, equals(1));
      expect(archive[0].name, equals('base256.txt'));
      expect(archive[0].readBytes(), equals(utf8.encode('hello base256\n')));

      // A 16GB file, whose size doesn't fit the octal field at all.
      decoder.decodeBytes(
          File('test/_data/tar/writer-big.tar').readAsBytesSync(),
          storeData: false);
      expect(decoder.files.length, equals(1));
      expect(decoder.files[0].fileSize, equals(17179869184));

      // The field is 88 bits wide, more than an int holds. A value that
      // doesn't fit has to be refused, not reported as something unrelated.
      final tooWide = Uint8List(1024);
      tooWide.setRange(0, 5, 'a.txt'.codeUnits);
      tooWide.setRange(124, 136, [0x80, 0x7f, ...List.filled(10, 0xff)]);
      tooWide[156] = 0x30;
      tooWide.setRange(257, 263, 'ustar '.codeUnits);
      expect(() => TarDecoder().decodeBytes(tooWide),
          throwsA(isA<ArchiveException>()));

      // The encoding can express a negative number, which no size can be.
      final header = Uint8List(1024);
      header.setRange(0, 5, 'a.txt'.codeUnits);
      header.fillRange(124, 136, 0xff);
      header[156] = 0x30; // normal file
      header.setRange(257, 263, 'ustar '.codeUnits);
      expect(() => TarDecoder().decodeBytes(header),
          throwsA(isA<ArchiveException>()));
    });

    test('base 256 encoded header fields on the way out', () {
      // Too wide for the octal field used to be truncated to its leading
      // digits: a different number, in an archive nothing reports as damaged
      final file = ArchiveFile.bytes('a.txt', Uint8List.fromList([1, 2, 3]));
      file.ownerId = 16777216;
      file.groupId = -1;
      final encoded = TarEncoder().encodeBytes(Archive()..add(file));
      // The bytes libarchive writes for the same uid
      expect(encoded.sublist(108, 116),
          equals([0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]));
      expect(encoded.sublist(116, 124), equals(List.filled(8, 0xff)));

      final back = TarDecoder().decodeBytes(encoded, verify: true);
      expect(back[0].ownerId, equals(16777216));
      expect(back[0].groupId, equals(-1));

      // One less still fits as digits and stays there, since older readers
      // read those but not base 256
      final widest = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      widest.ownerId = 16777215;
      final octal = TarEncoder().encodeBytes(Archive()..add(widest));
      expect(octal.sublist(108, 116), equals('77777777'.codeUnits));
      expect(TarDecoder().decodeBytes(octal, verify: true)[0].ownerId,
          equals(16777215));

      // Reaching the marker and sign bits of the first byte is refused
      final tooWide = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      tooWide.ownerId = 1 << 62;
      expect(() => TarEncoder().encodeBytes(Archive()..add(tooWide)),
          throwsA(isA<ArchiveException>()));

      // As is anything the decoder would refuse to read back: it stops at
      // 2^53-1, the widest integer that is exact on every platform
      final unreadable = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      unreadable.ownerId = 1 << 53;
      expect(() => TarEncoder().encodeBytes(Archive()..add(unreadable)),
          throwsA(isA<ArchiveException>()));
      final widestExact = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      widestExact.ownerId = (1 << 53) - 1;
      widestExact.groupId = -(1 << 53);
      final exact = TarEncoder().encodeBytes(Archive()..add(widestExact));
      expect(TarDecoder().decodeBytes(exact, verify: true)[0].ownerId,
          equals((1 << 53) - 1));
      expect(TarDecoder().decodeBytes(exact, verify: true)[0].groupId,
          equals(-(1 << 53)));
    });

    test('an entry given as a stream is not pulled into memory to encode', () {
      // Reading an entry whole fails past the size one read can return
      final data = Uint8List.fromList(List.generate(4096, (i) => i & 0xff));
      final file = ArchiveFile.stream('a.txt', _RefusesBulkRead(data));
      final path = p.join(Directory.systemTemp.path, 'tar_stream_entry.tar');
      final out = OutputFileStream(path);
      TarEncoder().encodeStream(Archive()..add(file), out);
      out.closeSync();

      final back =
          TarDecoder().decodeStream(InputFileStream(path), verify: true);
      expect(back.length, equals(1));
      expect(back[0].readBytes(), equals(data));
    });

    test('encoding a stream entry leaves its stream where it was', () {
      // A file output copies the stream in chunks, which used to advance it,
      // so a second encode or a read of the entry afterwards saw nothing
      final data = Uint8List.fromList(List.generate(3000, (i) => i & 0xff));
      final archive = Archive()
        ..add(ArchiveFile.stream('a.txt', InputMemoryStream(data)));
      for (final name in ['tar_stream_twice_1.tar', 'tar_stream_twice_2.tar']) {
        final path = p.join(Directory.systemTemp.path, name);
        final out = OutputFileStream(path);
        TarEncoder().encodeStream(archive, out);
        out.closeSync();
        final input = InputFileStream(path);
        final back = TarDecoder().decodeStream(input, verify: true);
        expect(back.length, equals(1));
        expect(back[0].size, equals(data.length));
        expect(back[0].readBytes(), equals(data));
        input.closeSync();
      }
      expect(archive[0].readBytes(), equals(data));
    });

    test('content set on a TarFile reads back', () {
      // The getter used to answer null for a file with no raw content, even
      // after content was set
      final file = TarFile()..content = FileContentMemory([1, 2, 3]);
      expect(file.contentBytes, equals([1, 2, 3]));
      final bytes = TarFile()..contentBytes = Uint8List.fromList([4, 5]);
      expect(bytes.contentBytes, equals([4, 5]));
      expect(TarFile().content, isNull);
    });

    test('a tail too short for a header ends the archive', () {
      // Without end blocks, junk after the last entry used to be read as an
      // entry when it was long enough to hold a name
      final good = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', Uint8List.fromList([1, 2, 3])))
        ..add(ArchiveFile.bytes('b.txt', Uint8List.fromList([4, 5, 6]))));
      final noEnd = good.sublist(0, good.length - 1024);
      for (final tail in [1, 2, 100, 511]) {
        final junk = Uint8List.fromList([...noEnd, ...List.filled(tail, 0x78)]);
        expect(TarDecoder().decodeBytes(junk).length, equals(2),
            reason: '$tail bytes');
        // With verify nothing after the last entry but zeros is accepted
        expect(() => TarDecoder().decodeBytes(junk, verify: true),
            throwsA(isA<ArchiveException>()),
            reason: '$tail bytes');
        // Past the end blocks it is not looked at
        final after = Uint8List.fromList([...good, ...List.filled(tail, 0x78)]);
        expect(TarDecoder().decodeBytes(after, verify: true).length, equals(2),
            reason: '$tail bytes');
      }
    });

    test('a decoded file is not a symbolic link', () {
      // The link name field is read for every header, and its empty string
      // used to be kept, so a decoded file re-encoded as a symbolic link
      final data = Uint8List.fromList([1, 2, 3]);
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', data))
        ..add(ArchiveFile.symlink('b.txt', 'a.txt')));
      final decoded = TarDecoder().decodeBytes(tar, verify: true);
      expect(decoded[0].isSymbolicLink, isFalse);
      expect(decoded[0].symbolicLink, isNull);
      expect(decoded[1].isSymbolicLink, isTrue);
      expect(decoded[1].symbolicLink, equals('a.txt'));

      final again = TarDecoder()
          .decodeBytes(TarEncoder().encodeBytes(decoded), verify: true);
      expect(again[0].size, equals(data.length));
      expect(again[0].readBytes(), equals(data));
      expect(again[1].symbolicLink, equals('a.txt'));
    });

    test('long names are measured in bytes', () {
      // The separate file for a long name used to be sized in UTF-16 units
      // and filled with UTF-8 bytes, so any non-ASCII long name misaligned
      // the archive; and a name long in bytes but short in characters was
      // cut to fit the header field
      for (final name in ['${'é' * 101}.txt', '${'日' * 60}.txt']) {
        final data = Uint8List.fromList([1, 2, 3]);
        final tar = TarEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes(name, data))
          ..add(ArchiveFile.bytes('b.txt', data)));
        final back = TarDecoder().decodeBytes(tar, verify: true);
        expect(back.length, equals(2), reason: name);
        expect(back[0].name, equals(name));
        expect(back[0].readBytes(), equals(data));
        expect(back[1].name, equals('b.txt'));
      }
    });

    test('a long name is written with the GNU type flag', () {
      // The '././@LongLink' entry used to go out as a regular file. This
      // decoder reads the name back either way, but every other tar keys on
      // the type flag alone and cut the name to the 100 byte field without it
      final name = '${'c' * 150}.txt';
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes(name, Uint8List(3))));
      expect(String.fromCharCode(tar[156]), equals(TarFile.longName));
      expect(String.fromCharCode(tar[512 + 512 + 156]), equals('0'));
      expect(TarDecoder().decodeBytes(tar, verify: true)[0].name, equals(name));
    });

    test('a long link target is written with the GNU type flag', () {
      // A target too long for the 100 byte field used to be cut to fit, so
      // even this decoder read back a different link than was written
      final target = '${'t' * 150}.txt';
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.symlink('link.txt', target)));
      expect(String.fromCharCode(tar[156]), equals(TarFile.longLinkName));
      expect(String.fromCharCode(tar[512 + 512 + 156]),
          equals(TarFile.symbolicLink));
      final back = TarDecoder().decodeBytes(tar, verify: true)[0];
      expect(back.name, equals('link.txt'));
      expect(back.symbolicLink, equals(target));
    });

    test('a long name and a long target are both written, name first', () {
      final name = '${'n' * 150}.txt';
      final target = '${'t' * 150}.txt';
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.symlink(name, target)));
      expect(String.fromCharCode(tar[156]), equals(TarFile.longName));
      expect(String.fromCharCode(tar[512 + 512 + 156]),
          equals(TarFile.longLinkName));
      final back = TarDecoder().decodeBytes(tar, verify: true)[0];
      expect(back.name, equals(name));
      expect(back.symbolicLink, equals(target));
    });

    test('verify rejects a damaged header that starts with zeros', () {
      // A header damaged into starting with zeros used to end the archive,
      // dropping every entry behind it
      final good = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', Uint8List.fromList([1, 2, 3])))
        ..add(ArchiveFile.bytes('b.txt', Uint8List.fromList([4, 5, 6]))));
      expect(TarDecoder().decodeBytes(good, verify: true).length, equals(2));

      // This encoder zeroes everything past the link name, so blanking more
      // than that is a real end block
      for (final zeros in [2, 8, 100]) {
        final damaged = Uint8List.fromList(good);
        damaged.fillRange(1024, 1024 + zeros, 0);
        expect(() => TarDecoder().decodeBytes(damaged, verify: true),
            throwsA(isA<ArchiveException>()),
            reason: '$zeros leading zeros');
        // Without verify nothing is checked, so the archive still ends there
        expect(TarDecoder().decodeBytes(damaged).length, equals(1),
            reason: '$zeros leading zeros');
      }

      // A whole block of zeros is the end of the archive, and stays that way
      final ended = Uint8List.fromList(good);
      ended.fillRange(1024, 1536, 0);
      expect(TarDecoder().decodeBytes(ended, verify: true).length, equals(1));
    });

    test('long file name not null terminated', () async {
      final bytes = await http.readBytes(Uri.parse(
          'https://pub.dev/packages/firebase_messaging/versions/10.0.8.tar.gz'));
      final tarBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      final archive = TarDecoder().decodeBytes(tarBytes, verify: true);
      expect(archive.length, equals(129));
      expect(
          archive[13].name,
          equals(
              'android/src/main/java/io/flutter/plugins/firebase/messaging/FlutterFirebaseMessagingBackgroundExecutor.java'));
    });

    test('symlink', () {
      var file = File('test/_data/tar/symlink_tar.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(4));
      expect(archive[1].isSymbolicLink, equals(true));
      expect(archive[1].symbolicLink, equals('b/b.txt'));
    });

    test('decode test2.tar', () {
      final file = File('test/_data/test2.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);

      final expectedFiles = <File>[];
      listDir(expectedFiles, Directory('test/_data/test2'));

      expect(archive.length, equals(4));
    });

    test('decode test2.tar.gz', () {
      final file = File('test/_data/test2.tar.gz');
      var bytes = file.readAsBytesSync();

      bytes = GZipDecoder().decodeBytes(bytes, verify: true);
      final archive = TarDecoder().decodeBytes(bytes, verify: true);

      final expectedFiles = <File>[];
      listDir(expectedFiles, Directory('test/_data/test2'));

      expect(archive.length, equals(4));
    });

    test('decode/encode', () {
      /*final aBytes = aTxt.codeUnits;

      var b = File('test/_data/cat.jpg');
      List<int> bBytes = b.readAsBytesSync();

      var file = File('test/_data/test.tar');
      final bytes = file.readAsBytesSync();

      final archive = tar.decodeBytes(bytes, verify: true);
      expect(archive.length, equals(2));

      var tFile = archive.fileName(0);
      expect(tFile, equals('a.txt'));
      var tBytes = archive.fileData(0);
      compareBytes(tBytes, aBytes);

      tFile = archive.fileName(1);
      expect(tFile, equals('cat.jpg'));
      tBytes = archive.fileData(1);
      compareBytes(tBytes, bBytes);

      final encoded = tarEncoder.encode(archive);
      final out = File(p.join(testOutputPath, 'test.tar'));
      out.createSync(recursive: true);
      out.writeAsBytesSync(encoded);

      // Test round-trip
      final archive2 = tar.decodeBytes(encoded, verify: true);
      expect(archive2.length, equals(2));

      tFile = archive2.fileName(0);
      expect(tFile, equals('a.txt'));
      tBytes = archive2.fileData(0);
      compareBytes(tBytes, aBytes);

      tFile = archive2.fileName(1);
      expect(tFile, equals('cat.jpg'));
      tBytes = archive2.fileData(1);
      compareBytes(tBytes, bBytes);*/
    });

    for (Map<String, dynamic> t in tarTests) {
      test('untar ${t['file']}', () {
        final file = File(p.join('test', t['file'] as String));
        final bytes = file.readAsBytesSync();

        final tar = TarDecoder();
        /*Archive archive =*/
        tar.decodeBytes(bytes, verify: true);
        expect(tar.files.length, equals(t['headers'].length));

        for (var i = 0; i < tar.files.length; ++i) {
          final file = tar.files[i];
          final hdr = t['headers'][i] as Map<String, dynamic>;

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
          if (hdr.containsKey('Linkname')) {
            expect(file.nameOfLinkedFile, equals(hdr['Linkname']));
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
  });
}

// A stream that can be read a piece at a time but never all at once
class _RefusesBulkRead extends InputMemoryStream {
  _RefusesBulkRead(super.bytes);

  @override
  Uint8List toUint8List() => throw StateError('entry pulled into memory');
}

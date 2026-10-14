import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
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
  {
    'file': '_data/tar/ustar.tar',
    'headers': [
      {
        'Name': '${'longname/' * 15}file.txt',
        'Mode': int.parse('0644', radix: 8),
        'Uid': int.parse('0765', radix: 8),
        'Gid': int.parse('024', radix: 8),
        'Size': 6,
        'ModTime': 1360135598,
        'Typeflag': TarFile.normalFile,
        'Uname': 'shane',
        'Gname': 'staff',
      },
    ],
  },
  {
    'file': '_data/tar/gnu-incremental.tar',
    'headers': [
      {
        'Name': 'test2/',
        'Mode': 16877,
        'Uid': 1000,
        'Gid': 1000,
        'Size': 14,
        'ModTime': 1441973427,
        'Typeflag': 'D',
        'Uname': 'rawr',
        'Gname': 'dsnet',
      },
      {
        'Name': 'test2/foo',
        'Mode': 33188,
        'Uid': 1000,
        'Gid': 1000,
        'Size': 64,
        'ModTime': 1441973363,
        'Typeflag': TarFile.normalFile,
        'Uname': 'rawr',
        'Gname': 'dsnet',
      },
      {
        'Name': 'test2/sparse',
        'Mode': 33188,
        'Uid': 1000,
        'Gid': 1000,
        'ModTime': 1441973427,
        'Typeflag': 'S',
        'Uname': 'rawr',
        'Gname': 'dsnet',
      },
    ],
  },
];

void main() {
  group('tar', () {
    test('keepEntries false passes entries only to the callback', () {
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 3; i++) ...[
          ..._tarHeader('f$i', TarFile.normalFile, 1),
          ..._tarBlocks([0x30 + i]),
        ],
        ...Uint8List(1024),
      ]);
      final seen = <String>[];
      final decoder = TarDecoder();
      final archive = decoder.decodeBytes(bytes,
          keepEntries: false,
          callback: (f) => seen.add('${f.name}=${f.readBytes()![0]}'));
      expect(seen, equals(['f0=48', 'f1=49', 'f2=50']));
      expect(archive, isEmpty);
      expect(decoder.files, isEmpty);
    });

    test('long name entry without a terminating null', () {
      final name = 'n' * 300;
      final bytes = Uint8List.fromList([
        ..._tarHeader('././@LongLink', TarFile.longName, name.length,
            magic: 'ustar\u000000'),
        ..._tarBlocks(ascii.encode(name)),
        ..._tarHeader('short', TarFile.normalFile, 0, magic: 'ustar\u000000'),
        ...Uint8List(1024),
      ]);
      final archive = TarDecoder().decodeBytes(bytes);
      expect(archive.length, equals(1));
      expect(archive[0].name, equals(name));
    });

    test('refuses metadata entries larger than maxMetadataSize', () {
      // Their content is read whole, so a few KB of .tar.gz declaring a long
      // name of hundreds of MB used to take gigabytes to decode.
      for (final type in [
        TarFile.longName,
        TarFile.longLinkName,
        TarFile.exHeader,
        TarFile.gExHeader,
      ]) {
        final bytes = Uint8List.fromList([
          ..._tarHeader('././@LongLink', type, TarFile.maxMetadataSize + 1,
              magic: 'ustar\u000000'),
          ...Uint8List(TarFile.maxMetadataSize + 512),
          ...Uint8List(1024),
        ]);
        expect(() => TarDecoder().decodeBytes(bytes),
            throwsA(isA<ArchiveLimitException>()),
            reason: type);
      }
      // Up to the limit is still read.
      final name = 'n' * TarFile.maxMetadataSize;
      final bytes = Uint8List.fromList([
        ..._tarHeader('././@LongLink', TarFile.longName, name.length,
            magic: 'ustar\u000000'),
        ..._tarBlocks(ascii.encode(name)),
        ..._tarHeader('short', TarFile.normalFile, 0, magic: 'ustar\u000000'),
        ...Uint8List(1024),
      ]);
      expect(TarDecoder().decodeBytes(bytes)[0].name.length,
          equals(TarFile.maxMetadataSize));
    });

    // bsdtar makes a real hard link, Python tarfile and 7-Zip 26 write a copy
    test('hard link target is relative to link folder', () {
      final out = OutputMemoryStream();
      final tar = TarEncoder()..start(out);
      tar.add(ArchiveFile.string('usr/bin/gcc', 'compiler'));
      (TarFile()
            ..filename = 'usr/bin/gcc-13'
            ..typeFlag = TarFile.hardLink
            ..nameOfLinkedFile = 'usr/bin/gcc'
            ..mode = 0x1ed)
          .write(out);
      tar.finish();
      final link = TarDecoder()
          .decodeBytes(out.getBytes())
          .files
          .singleWhere((f) => f.name == 'usr/bin/gcc-13');
      expect(link.symbolicLink, 'gcc');
      expect(link.isHardLink, isTrue);

      final again = TarDecoder();
      again.decodeBytes(TarEncoder().encodeBytes(Archive()..add(link)));
      expect(again.files.single.typeFlag, TarFile.hardLink);
      expect(again.files.single.nameOfLinkedFile, 'usr/bin/gcc');
    });

    test('unreadable zip entry does not drop entries after it', () async {
      final data = Uint8List.fromList(List.generate(3000, (i) => i * 7 % 251));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('odd', data))
        ..add(ArchiveFile.bytes('good', data)));
      final view = ByteData.sublistView(zip);
      for (var at = 0; at + 46 < zip.length; at++) {
        final signature = view.getUint32(at, Endian.little);
        final central = signature == 0x02014b50;
        if (!central && signature != 0x04034b50) {
          continue;
        }
        final nameAt = at + (central ? 46 : 30);
        if (String.fromCharCodes(zip, nameAt, nameAt + 3) == 'odd') {
          view.setUint16(at + (central ? 10 : 8), 9, Endian.little);
        }
      }
      final streamed = await tarCodec.encoder
          .bind(Stream.fromIterable(ZipDecoder().decodeBytes(zip).files))
          .expand((piece) => piece)
          .toList();
      for (final (name, tar) in [
        (
          'encodeBytes',
          TarEncoder().encodeBytes(ZipDecoder().decodeBytes(zip))
        ),
        ('tarCodec', streamed),
      ]) {
        expect(
            () => TarDecoder().decodeBytes(tar, verify: true), returnsNormally,
            reason: name);
        final files = TarDecoder().decodeBytes(tar).files;
        expect(files.map((f) => f.name), ['odd', 'good'], reason: name);
        expect(files.last.content, data, reason: name);
      }
    });

    test('entry whose stream was written to file is encoded whole',
        testOn: 'vm', () async {
      final directory = Directory.systemTemp.createTempSync('archive-tar-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final data = Uint8List.fromList(List.generate(3000, (i) => i * 7 % 251));
      final source = File(p.join(directory.path, 'source.bin'))
        ..writeAsBytesSync(data);
      final input = InputFileStream(source.path);
      addTearDown(input.closeSync);
      for (final entry in [
        ArchiveFile.stream('file', input),
        ArchiveFile.stream('memory', InputMemoryStream(data)),
      ]) {
        final output = OutputFileStream(p.join(directory.path, entry.name));
        entry.writeContent(output);
        output.closeSync();
        final streamed = await tarCodec.encoder
            .bind(
                Stream.fromIterable([entry, ArchiveFile.string('after', 'a')]))
            .expand((piece) => piece)
            .toList();
        for (final (name, tar) in [
          (
            'encodeBytes',
            TarEncoder().encodeBytes(Archive()
              ..add(entry)
              ..add(ArchiveFile.string('after', 'a')))
          ),
          ('tarCodec', streamed),
        ]) {
          final files = TarDecoder().decodeBytes(tar, verify: true).files;
          expect(files.map((f) => f.name), [entry.name, 'after'],
              reason: '${entry.name}, $name');
          expect(files.first.content, data, reason: '${entry.name}, $name');
        }
      }
    });

    test('entry whose stream was read is encoded same as from memory',
        testOn: 'vm', () async {
      final directory = Directory.systemTemp.createTempSync('archive-tar-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final data = Uint8List.fromList(List.generate(3000, (i) => i * 7 % 251));
      final source = File(p.join(directory.path, 'source.bin'))
        ..writeAsBytesSync(data);
      final contents = <String, List<int>>{};
      for (final input in [
        InputFileStream(source.path),
        InputMemoryStream(data),
      ]) {
        addTearDown(input.closeSync);
        final kind = input is InputFileStream ? 'file' : 'memory';
        final entry = ArchiveFile.stream('entry', input);
        input.readBytes(4);
        final streamed = await tarCodec.encoder
            .bind(
                Stream.fromIterable([entry, ArchiveFile.string('after', 'a')]))
            .expand((piece) => piece)
            .toList();
        for (final (name, tar) in [
          (
            'encodeBytes',
            TarEncoder().encodeBytes(Archive()
              ..add(entry)
              ..add(ArchiveFile.string('after', 'a')))
          ),
          ('tarCodec', streamed),
        ]) {
          final files = TarDecoder().decodeBytes(tar, verify: true).files;
          expect(files.map((f) => f.name), ['entry', 'after'],
              reason: '$kind, $name');
          contents['$kind $name'] = files.first.content;
        }
      }
      expect(contents['file encodeBytes'], contents['memory encodeBytes']);
      expect(contents['file tarCodec'], contents['memory tarCodec']);
    });

    test('hard link in v7 or GNU tar has no data regardless of size field',
        () async {
      for (final magic in ['', 'ustar  \u0000']) {
        final bytes = Uint8List.fromList([
          ..._tarHeader('docs/README', '0', 321, magic: magic),
          ..._tarBlocks(List.filled(321, 0x72)),
          ..._tarHeader('README', '1', 321, link: 'docs/README', magic: magic),
          ..._tarHeader('after', '0', 1, magic: magic),
          ..._tarBlocks([0x61]),
          ...Uint8List(1024),
        ]);
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final files = TarDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .files;
          final reason = 'magic ${magic.length}, verify $verify, '
              'throwOnError $throwOnError';
          expect(files.map((f) => f.name), ['docs/README', 'README', 'after'],
              reason: reason);
          expect(files[1].isHardLink, isTrue, reason: reason);
          expect(files[1].symbolicLink, 'docs/README', reason: reason);
          expect(files[2].content, [0x61], reason: reason);
        }
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async =>
                '${e.name}=${(await e.content.expand((b) => b).toList()).length}')
            .toList();
        expect(streamed, ['docs/README=321', 'README=0', 'after=1'],
            reason: 'magic ${magic.length}');
      }
    });

    test('hard link in pax archive keeps its data', () async {
      final records = utf8.encode(_paxRecord('mtime', '1'));
      for (final type in ['x', 'g']) {
        final bytes = Uint8List.fromList([
          ..._tarHeader('PaxHeaders/README', type, records.length,
              magic: 'ustar\u000000'),
          ..._tarBlocks(records),
          ..._tarHeader('docs/README', '0', 3, magic: 'ustar\u000000'),
          ..._tarBlocks([0x72, 0x72, 0x72]),
          ..._tarHeader('README', '1', 3,
              link: 'docs/README', magic: 'ustar\u000000'),
          ..._tarBlocks([0x6c, 0x6c, 0x6c]),
          ..._tarHeader('after', '0', 1, magic: 'ustar\u000000'),
          ..._tarBlocks([0x61]),
          ...Uint8List(1024),
        ]);
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final files = TarDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .files;
          final reason = 'type $type, verify $verify, '
              'throwOnError $throwOnError';
          expect(files.map((f) => f.name), ['docs/README', 'README', 'after'],
              reason: reason);
          expect(files[1].isHardLink, isTrue, reason: reason);
          expect(files[1].content, [0x6c, 0x6c, 0x6c], reason: reason);
          expect(files[2].content, [0x61], reason: reason);
        }
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async =>
                '${e.name}=${(await e.content.expand((b) => b).toList()).length}')
            .toList();
        expect(streamed, ['docs/README=3', 'README=3', 'after=1'],
            reason: 'type $type');
      }
    });

    test('hard link has data only where libarchive reads data', () async {
      const ustar = 'ustar\u000000';
      const gnu = 'ustar  \u0000';
      final records = utf8.encode(_paxRecord('mtime', '1'));
      final pax = [
        ..._tarHeader('PaxHeaders/p', 'x', records.length, magic: ustar),
        ..._tarBlocks(records),
        ..._tarHeader('p', '0', 0, magic: ustar),
      ];
      final longName = utf8.encode('long');
      final cases = [
        (
          'gnu link after pax',
          [
            ...pax,
            ..._tarHeader('link', '1', 3, link: 'p', magic: gnu),
          ],
          0
        ),
        (
          'ustar link after gnu entry',
          [
            ...pax,
            ..._tarHeader('q', '0', 0, magic: gnu),
            ..._tarHeader('link', '1', 3, link: 'p', magic: ustar),
          ],
          0
        ),
        (
          'ustar link after gnu long name',
          [
            ...pax,
            ..._tarHeader('././@LongLink', 'L', longName.length, magic: gnu),
            ..._tarBlocks(longName),
            ..._tarHeader('link', '1', 3, link: 'p', magic: ustar),
          ],
          0
        ),
        (
          'ustar link without version 00',
          [
            ..._tarHeader('p', '0', 0, magic: ustar),
            ..._tarHeader('link', '1', 3, link: 'p', magic: 'ustar\u0000'),
            ..._tarBlocks([0x6c, 0x6c, 0x6c]),
          ],
          3
        ),
      ];
      for (final (name, entries, linkSize) in cases) {
        final bytes = Uint8List.fromList([
          ...entries,
          ..._tarHeader('after', '0', 1, magic: ustar),
          ..._tarBlocks([0x61]),
          ...Uint8List(1024)
        ]);
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final files = TarDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .files;
          final reason = '$name, verify $verify, throwOnError $throwOnError';
          expect(files.last.name, 'after', reason: reason);
          expect(files.last.content, [0x61], reason: reason);
          expect(files[files.length - 2].isHardLink, isTrue, reason: reason);
          expect(files[files.length - 2].size, linkSize, reason: reason);
        }
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap(
                (e) async => (await e.content.expand((b) => b).toList()).length)
            .toList();
        expect(streamed.sublist(streamed.length - 2), [linkSize, 1],
            reason: name);
      }
    });

    test('hard link whose header fails libarchive bid keeps its data', () {
      const ustar = 'ustar\u000000';
      final badSum = _tarHeader('link', '1', 3, link: 'p', magic: ustar);
      badSum[148] = 0x37;
      for (final (name, link) in [
        ('checksum', badSum),
        (
          'uid',
          _tarHeader('link', '1', 3,
              link: 'p', magic: ustar, fields: {108: '00000x0\u0000'})
        ),
      ]) {
        final bytes = Uint8List.fromList([
          ..._tarHeader('p', '0', 0, magic: ustar),
          ...link,
          ..._tarBlocks([0x6c, 0x6c, 0x6c]),
          ..._tarHeader('after', '0', 1, magic: ustar),
          ..._tarBlocks([0x61]),
          ...Uint8List(1024),
        ]);
        final files = TarDecoder().decodeBytes(bytes).files;
        expect(files.map((f) => f.name), ['p', 'link', 'after'], reason: name);
        expect(files[1].content, [0x6c, 0x6c, 0x6c], reason: name);
        expect(files[2].content, [0x61], reason: name);
      }
    });

    test('directory, link, device or fifo has no data regardless of size field',
        () async {
      final records = utf8.encode(_paxRecord('mtime', '1'));
      for (final (name, type) in [
        ('dir/', '5'),
        ('symlink', '2'),
        ('null', '3'),
        ('sda', '4'),
        ('fifo', '6'),
      ]) {
        for (final pax in [false, true]) {
          final bytes = Uint8List.fromList([
            if (pax) ...[
              ..._tarHeader('PaxHeaders/$name', 'x', records.length,
                  magic: 'ustar\u000000'),
              ..._tarBlocks(records),
            ],
            ..._tarHeader(name, type, 255,
                link: type == '2' ? 'after' : '', magic: 'ustar\u000000'),
            ..._tarHeader('after', '0', 1, magic: 'ustar\u000000'),
            ..._tarBlocks([0x61]),
            ...Uint8List(1024),
          ]);
          for (final (verify, throwOnError) in [
            (false, false),
            (true, false),
            (false, true)
          ]) {
            final files = TarDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
                .files;
            final reason = 'type $type, pax $pax, verify $verify, '
                'throwOnError $throwOnError';
            expect(files.map((f) => f.name), [name, 'after'], reason: reason);
            expect(files[1].content, [0x61], reason: reason);
          }
          final streamed = await Stream<List<int>>.value(bytes)
              .transform(tarCodec.decoder)
              .asyncMap((e) async =>
                  '${e.name}=${(await e.content.expand((b) => b).toList()).length}')
              .toList();
          expect(streamed, ['$name=0', 'after=1'],
              reason: 'type $type, pax $pax');
        }
      }
    });

    test('sparse file decodes with zero-filled holes', () async {
      final data = [...List.filled(512, 0x61), ...List.filled(512, 0x62)];
      final expanded = [
        ...List.filled(512, 0x61),
        ...Uint8List(1024),
        ...List.filled(512, 0x62)
      ];
      final gnu = Uint8List.fromList([
        ..._tarHeader('gnu.bin', 'S', 1024, magic: 'ustar  \u0000', fields: {
          386: '00000000000\u0000',
          398: '00000001000\u0000',
          410: '00000003000\u0000',
          422: '00000001000\u0000',
          483: '00000004000\u0000',
        }),
        ...data,
        ...Uint8List(1024),
      ]);
      final records = utf8.encode(_paxRecord('GNU.sparse.major', '1') +
          _paxRecord('GNU.sparse.minor', '0') +
          _paxRecord('GNU.sparse.name', 'pax.bin') +
          _paxRecord('GNU.sparse.realsize', '2048'));
      final pax = Uint8List.fromList([
        ..._tarHeader('PaxHeaders/pax.bin', 'x', records.length,
            magic: 'ustar\u000000'),
        ..._tarBlocks(records),
        ..._tarHeader('GNUSparseFile.0/pax.bin', '0', 512 + data.length,
            magic: 'ustar\u000000'),
        ..._tarBlocks(ascii.encode('2\n0\n512\n1536\n512\n')),
        ...data,
        ...Uint8List(1024),
      ]);
      for (final (name, bytes) in [('gnu.bin', gnu), ('pax.bin', pax)]) {
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final file = TarDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .single;
          final reason = '$name, verify $verify, throwOnError $throwOnError';
          expect(file.name, name, reason: reason);
          expect(file.size, expanded.length, reason: reason);
          expect(file.content, expanded, reason: reason);
        }
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async =>
                (e.name, await e.content.expand((b) => b).toList()))
            .toList();
        expect(streamed.single.$1, name);
        expect(streamed.single.$2, expanded, reason: name);
      }
    });

    test('truncated sparse file gives regions that arrived', () {
      final data = [...List.filled(512, 0x61), ...List.filled(512, 0x62)];
      final expanded = [
        ...List.filled(512, 0x61),
        ...Uint8List(1024),
        ...List.filled(512, 0x62)
      ];
      final gnu = [
        ..._tarHeader('gnu.bin', 'S', 1024, magic: 'ustar  \u0000', fields: {
          386: '00000000000\u0000',
          398: '00000001000\u0000',
          410: '00000003000\u0000',
          422: '00000001000\u0000',
          483: '00000004000\u0000',
        }),
        ...data,
      ];
      for (final (arrived, prefix) in [
        (0, 0),
        (100, 100),
        (512, 1536),
        (600, 1624)
      ]) {
        final bytes = Uint8List.fromList(gnu.sublist(0, 512 + arrived));
        final file = TarDecoder().decodeBytes(bytes).single;
        final reason = '$arrived bytes of data';
        final written = OutputMemoryStream();
        file.writeContent(written);
        final content = file.content;
        expect(file.size, prefix, reason: reason);
        expect(content, expanded.take(prefix), reason: reason);
        expect(written.getBytes(), content, reason: reason);
        expect(() => TarDecoder().decodeBytes(bytes, throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: reason);
      }
    });

    test('sparse map that does not fit leaves entry as stored', () async {
      final data = [...List.filled(512, 0x61), ...List.filled(512, 0x62)];
      List<int> pax(String type, Map<String, String> records) {
        final bytes = utf8.encode(
            records.entries.map((r) => _paxRecord(r.key, r.value)).join());
        return [
          ..._tarHeader('PaxHeaders/x', type, bytes.length,
              magic: 'ustar\u000000'),
          ..._tarBlocks(bytes),
        ];
      }

      List<int> pax10(String map) {
        final stored = [..._tarBlocks(ascii.encode(map)), ...data];
        return [
          ...pax('x', {
            'GNU.sparse.major': '1',
            'GNU.sparse.minor': '0',
            'GNU.sparse.name': 'pax.bin',
            'GNU.sparse.realsize': '2048',
          }),
          ..._tarHeader('GNUSparseFile.0/pax.bin', '0', stored.length,
              magic: 'ustar\u000000'),
          ...stored,
        ];
      }

      final cases = {
        'regions shorter than the data': (
          pax10('2\n0\n512\n1536\n500\n'),
          'pax.bin',
          [..._tarBlocks(ascii.encode('2\n0\n512\n1536\n500\n')), ...data],
        ),
        'a map that is not decimal': (
          pax10('2\n0\n512\n15x6\n512\n'),
          'pax.bin',
          [..._tarBlocks(ascii.encode('2\n0\n512\n15x6\n512\n')), ...data],
        ),
        'overlapping regions': (
          [
            ..._tarHeader('gnu.bin', 'S', 1024,
                magic: 'ustar  \u0000',
                fields: {
                  386: '00000000000\u0000',
                  398: '00000001000\u0000',
                  410: '00000000400\u0000',
                  422: '00000001000\u0000',
                  483: '00000004000\u0000',
                }),
            ...data,
          ],
          'gnu.bin',
          data,
        ),
        'a region past the real size': (
          [
            ...pax('x', {
              'GNU.sparse.size': '2048',
              'GNU.sparse.map': '0,512,1800,512',
              'GNU.sparse.name': 'real.bin',
            }),
            ..._tarHeader('stored.bin', '0', 1024, magic: 'ustar\u000000'),
            ...data,
          ],
          'real.bin',
          data,
        ),
      };
      for (final MapEntry(key: what, value: (entries, name, stored))
          in cases.entries) {
        final bytes = Uint8List.fromList([...entries, ...Uint8List(1024)]);
        final file = TarDecoder().decodeBytes(bytes).single;
        expect(file.name, name, reason: what);
        expect(file.content, stored, reason: what);
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => TarDecoder().decodeBytes(bytes,
                  verify: verify, throwOnError: throwOnError),
              throwsA(isA<ArchiveException>()),
              reason: '$what, verify $verify, throwOnError $throwOnError');
        }
        await expectLater(
            Stream<List<int>>.value(bytes)
                .transform(tarCodec.decoder)
                .asyncMap((e) => e.content.drain<void>())
                .toList(),
            throwsA(isA<ArchiveException>()),
            reason: what);
      }
    });

    test('GNU sparse header truncated before extension is read as stored', () {
      final bytes =
          _tarHeader('gnu.bin', 'S', 1024, magic: 'ustar  \u0000', fields: {
        386: '00000000000\u0000',
        398: '00000001000\u0000',
        410: '00000002000\u0000',
        422: '00000001000\u0000',
        482: '\u0001',
        483: '00000004000\u0000',
      });
      final file = TarDecoder().decodeBytes(bytes).single;
      expect(file.name, 'gnu.bin');
      expect(file.content, isEmpty);
      expect(
          () =>
              TarDecoder().decodeBytes(bytes, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('GNU sparse entry stored as is streams as regular file', () async {
      final bytes = Uint8List.fromList([
        ..._tarHeader('gnu.bin', 'S', 1024, magic: 'ustar  \u0000'),
        ...List.filled(1024, 0x61),
        ...Uint8List(1024),
      ]);
      expect(TarDecoder().decodeBytes(bytes).single.isFile, isTrue);
      final types = await Stream<List<int>>.value(bytes)
          .transform(tarCodec.decoder)
          .asyncMap((e) async {
        await e.content.drain<void>();
        return e.type;
      }).toList();
      expect(types, [TarEntryType.file]);
    });

    test('sparse map decodes as libarchive decodes it', () async {
      const ustar = 'ustar\u000000';
      final data = [...List.filled(512, 0x61), ...List.filled(512, 0x62)];
      final expanded = [
        ...List.filled(512, 0x61),
        ...Uint8List(1024),
        ...List.filled(512, 0x62)
      ];
      List<int> pax(List<(String, String)> records) {
        final bytes =
            utf8.encode(records.map((r) => _paxRecord(r.$1, r.$2)).join());
        return [
          ..._tarHeader('PaxHeaders/x', 'x', bytes.length, magic: ustar),
          ..._tarBlocks(bytes),
        ];
      }

      List<int> pax10(String name, String map,
          {List<(String, String)> records = const [], int? headerSize}) {
        final stored = [..._tarBlocks(ascii.encode(map)), ...data];
        return [
          ...pax(records),
          ..._tarHeader(
              'GNUSparseFile.0/$name', '0', headerSize ?? stored.length,
              magic: ustar),
          ...stored,
        ];
      }

      const v10 = [
        ('GNU.sparse.major', '1'),
        ('GNU.sparse.minor', '0'),
        ('GNU.sparse.realsize', '2048'),
      ];
      List<int> gnu(String type, Map<int, String> fields) => [
            ..._tarHeader('gnu.bin', type, 1024,
                magic: 'ustar  \u0000', fields: fields),
            ...data,
          ];

      final cases = <String, (List<int>, List<(String, List<int>)>)>{
        '1.0 comments, empty lines and a 100-byte line': (
          pax10('m.bin', '#a\n3\n${'0' * 99}\n#b\n512\n\n\n1536\n#c\n512\n',
              records: [
                ...v10,
                ('GNU.sparse.major', '11'),
                ('GNU.sparse.name', 'm.bin')
              ]),
          [('m.bin', expanded)]
        ),
        '1.0 data size from GNU.sparse.size': (
          pax10('m.bin', '2\n0\n512\n1536\n512\n', headerSize: 0, records: [
            ...v10,
            ('GNU.sparse.size', '1536'),
            ('GNU.sparse.name', 'm.bin')
          ]),
          [('m.bin', expanded)]
        ),
        '0.1 dangling offset, empty number and empty region': (
          [
            ...pax([
              ('GNU.sparse.size', '2048'),
              ('GNU.sparse.map', '0,512,,0,1536,512,100,0,4096'),
            ]),
            ..._tarHeader('m.bin', '0', 1024, magic: ustar),
            ...data,
          ],
          [('m.bin', expanded)]
        ),
        '0.0 pairs in arrival order, realsize over size': (
          [
            ...pax([
              ('GNU.sparse.size', '4096'),
              ('GNU.sparse.realsize', '2048'),
              ('GNU.sparse.numbytes', '512'),
              ('GNU.sparse.offset', '0'),
              ('GNU.sparse.offset', '1536'),
              ('GNU.sparse.numbytes', '512'),
            ]),
            ..._tarHeader('m.bin', '0', 1024, magic: ustar),
            ...data,
          ],
          [('m.bin', expanded)]
        ),
        'old GNU map on a regular GNU header': (
          gnu('0', {
            386: '00000000000\u0000',
            398: '00000001000\u0000',
            410: '00000003000\u0000',
            422: '00000001000\u0000',
            483: '00000004000\u0000',
          }),
          [('gnu.bin', expanded)]
        ),
        'old GNU numbers up to the first non-digit': (
          gnu('0', {
            386: '00000000000\u0000',
            398: '00000001000x',
            410: '00000003000\u0000',
            422: '00000001000\u0000',
            483: '00000004000\u0000',
          }),
          [('gnu.bin', expanded)]
        ),
        '1.0 map replaces a 0.1 map': (
          pax10('m.bin', '2\n0\n512\n1536\n512\n', records: [
            ('GNU.sparse.map', '0,1'),
            ...v10,
            ('GNU.sparse.name', 'm.bin')
          ]),
          [('m.bin', expanded)]
        ),
        '1.0 attributes on a non-regular type': (
          [
            ...pax(v10),
            ..._tarHeader('m.bin', '\u0000', 1536, magic: ustar),
            ..._tarBlocks(ascii.encode('2\n0\n512\n1536\n512\n')),
            ...data,
          ],
          [
            (
              'm.bin',
              [
                ..._tarBlocks(ascii.encode('2\n0\n512\n1536\n512\n')),
                ...data,
                ...Uint8List(512)
              ]
            )
          ]
        ),
        'isextended without a first region': (
          gnu('0', {482: '\u0001'}),
          [('gnu.bin', data)]
        ),
        'sparse version kept for the next entry': (
          [
            ...pax10('a.bin', '2\n0\n512\n1536\n512\n',
                records: [...v10, ('GNU.sparse.name', 'a.bin')]),
            ...pax10('b.bin', '2\n0\n512\n1536\n512\n', records: [
              ('GNU.sparse.realsize', '2048'),
              ('GNU.sparse.name', 'b.bin')
            ]),
          ],
          [('a.bin', expanded), ('b.bin', expanded)]
        ),
        'GNU.sparse alone marks the entry, GNU.sparse. does not': (
          [
            ...pax10('a.bin', '2\n0\n512\n1536\n512\n',
                records: [...v10, ('GNU.sparse.name', 'a.bin')]),
            ...pax10('c.bin', '2\n0\n512\n512\n512\n',
                records: [('GNU.sparse', '1')]),
            ...pax10('d.bin', '2\n0\n512\n512\n512\n',
                records: [('GNU.sparse.', '1')]),
          ],
          [
            ('a.bin', expanded),
            ('GNUSparseFile.0/c.bin', [...data, ...Uint8List(512)]),
            (
              'GNUSparseFile.0/d.bin',
              [..._tarBlocks(ascii.encode('2\n0\n512\n512\n512\n')), ...data]
            ),
          ]
        ),
      };
      for (final MapEntry(key: what, value: (entries, expected))
          in cases.entries) {
        final bytes = Uint8List.fromList([...entries, ...Uint8List(1024)]);
        for (final verify in [false, true]) {
          final files = TarDecoder().decodeBytes(bytes, verify: verify).files;
          expect(files.map((f) => f.name), expected.map((e) => e.$1),
              reason: '$what, verify $verify');
          expect(files.map((f) => f.content), expected.map((e) => e.$2),
              reason: '$what, verify $verify');
        }
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async =>
                (e.name, await e.content.expand((b) => b).toList()))
            .toList();
        expect(streamed.map((e) => e.$1), expected.map((e) => e.$1),
            reason: what);
        expect(streamed.map((e) => e.$2), expected.map((e) => e.$2),
            reason: what);
      }

      for (final (what, map, records) in [
        ('a 101-byte line', '2\n${'0' * 100}\n512\n1536\n512\n', v10),
        ('a length past int64', '2\n0\n18446744073709552128\n1536\n512\n', v10),
        (
          'a realsize longer than 64 bytes',
          '2\n0\n512\n1536\n512\n',
          [...v10, ('GNU.sparse.realsize', '${'0' * 61}2048')]
        ),
      ]) {
        final broken = pax10('m.bin', map,
            records: [...records, ('GNU.sparse.name', 'm.bin')]);
        final bytes = Uint8List.fromList([...broken, ...Uint8List(1024)]);
        final file = TarDecoder().decodeBytes(bytes).single;
        expect(file.name, 'm.bin', reason: what);
        expect(file.content, broken.sublist(broken.length - 1536),
            reason: what);
        expect(
            () => TarDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: what);
      }
    });

    test('sparse map applies only to regular file', () async {
      final records = utf8.encode(_paxRecord('GNU.sparse.size', '2048') +
          _paxRecord('GNU.sparse.map', '0,512,1536,512') +
          _paxRecord('GNU.sparse.name', 'real.bin'));
      final data = [...List.filled(512, 0x61), ...List.filled(512, 0x62)];
      final bytes = Uint8List.fromList([
        ..._tarHeader('PaxHeaders/link', 'x', records.length,
            magic: 'ustar\u000000'),
        ..._tarBlocks(records),
        ..._tarHeader('link', '2', 0, link: 'target', magic: 'ustar\u000000'),
        ..._tarHeader('posix.bin', 'S', 1024, magic: 'ustar\u000000', fields: {
          386: '00000000000\u0000',
          398: '00000001000\u0000',
          410: '00000003000\u0000',
          422: '00000001000\u0000',
          483: '00000004000\u0000',
        }),
        ...data,
        ...Uint8List(1024),
      ]);
      for (final (verify, throwOnError) in [
        (false, false),
        (true, false),
        (false, true)
      ]) {
        final files = TarDecoder()
            .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
            .files;
        final reason = 'verify $verify, throwOnError $throwOnError';
        expect(files.map((f) => f.name), ['real.bin', 'posix.bin'],
            reason: reason);
        expect(files[0].symbolicLink, 'target', reason: reason);
        expect(files[1].content, data, reason: reason);
      }
      final streamed = await Stream<List<int>>.value(bytes)
          .transform(tarCodec.decoder)
          .asyncMap((e) async => (
                e.name,
                e.symbolicLink,
                await e.content.expand((b) => b).toList()
              ))
          .toList();
      expect(streamed.map((e) => e.$1), ['real.bin', 'posix.bin']);
      expect(streamed[0].$2, 'target');
      expect(streamed[1].$3, data);
    });

    test('GNU tar sparse files decode as Go and libarchive decode them',
        testOn: 'vm', () async {
      final cases = {
        'sparse-formats.tar': [
          ('sparse-gnu', 200, 0x5375e1d2),
          ('sparse-posix-0.0', 200, 0x5375e1d2),
          ('sparse-posix-0.1', 200, 0x5375e1d2),
          ('sparse-posix-1.0', 200, 0x5375e1d2),
          ('end', 4, 0x8eb179ba),
        ],
        'gtar_sparse_1_17_posix10_modified.tar': [
          ('sparse', 3145728, 0x0f443b49),
          ('sparse2', 99000001, 0x4dd9ae72),
          ('non-sparse', 0, 0),
        ],
      };
      for (final MapEntry(key: name, value: expected) in cases.entries) {
        final bytes = File('test/_data/tar/$name').readAsBytesSync();
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final files = TarDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .files
              .where((f) => f.isFile);
          expect([for (final f in files) (f.name, f.size, getCrc32(f.content))],
              expected,
              reason: '$name, verify $verify, throwOnError $throwOnError');
        }
        expect(
            TarDecoder()
                .decodeBytes(bytes, storeData: false)
                .files
                .where((f) => f.isFile)
                .map((f) => f.name),
            expected.map((e) => e.$1),
            reason: name);
        final written = <(String, int, int)>[];
        for (final f in TarDecoder().decodeBytes(bytes).files) {
          if (f.isFile) {
            final out = OutputMemoryStream();
            f.writeContent(out);
            written.add((f.name, f.size, getCrc32(out.getBytes())));
          }
        }
        expect(written, expected, reason: name);
        final streamed = <(String, int, int)>[];
        await for (final entry
            in Stream<List<int>>.value(bytes).transform(tarCodec.decoder)) {
          var crc = 0;
          await for (final piece in entry.content) {
            crc = getCrc32(piece, crc);
          }
          if (entry.isFile) {
            streamed.add((entry.name, entry.size, crc));
          }
        }
        expect(streamed, expected, reason: name);
      }
      final truncated = File('test/_data/tar/sparse-formats.tar')
          .readAsBytesSync()
          .sublist(0, 3122);
      expect(
          () => TarDecoder()
              .decodeBytes(truncated, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('sparse entry streams its content in pieces', testOn: 'vm', () async {
      final data = List.generate(950, (i) => (i * 7 + 3) % 251);
      final expanded = Uint8List(3000)
        ..setRange(100, 400, data)
        ..setRange(1000, 1600, data, 300)
        ..setRange(2500, 2550, data, 900);
      final bytes = Uint8List.fromList([
        ..._tarHeader('gnu.bin', 'S', 950, magic: 'ustar  \u0000', fields: {
          386: '00000000144\u0000',
          398: '00000000454\u0000',
          410: '00000001750\u0000',
          422: '00000001130\u0000',
          434: '00000004704\u0000',
          446: '00000000062\u0000',
          483: '00000005670\u0000',
        }),
        ..._tarBlocks(data),
        ...Uint8List(1024),
      ]);
      final directory = Directory.systemTemp.createTempSync('archive-tar-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = p.join(directory.path, 'sparse.tar');
      File(path).writeAsBytesSync(bytes);
      final input = InputFileStream(path);
      addTearDown(input.closeSync);
      for (final (kind, archive) in [
        ('memory', TarDecoder().decodeBytes(bytes)),
        ('file', TarDecoder().decodeStream(input)),
      ]) {
        final file = archive.single;
        final written = p.join(directory.path, '$kind.bin');
        final output = OutputFileStream(written);
        file.writeContent(output, freeMemory: false);
        expect(output.length, expanded.length, reason: '$kind file');
        output.closeSync();
        expect(File(written).readAsBytesSync(), expanded, reason: '$kind file');
        final ram = RamFileHandle.asWritableRamBuffer();
        final toRam = OutputFileStream.toRamFile(ram);
        file.writeContent(toRam, freeMemory: false);
        toRam.flush();
        final back = Uint8List(ram.length);
        ram.readInto(back);
        expect(back, expanded, reason: '$kind ram');
        expect(file.content, expanded, reason: kind);
        for (final piece in [1, 7, 100, 1000, 4096]) {
          final stream = file.rawContent!.getStream();
          final read = BytesBuilder();
          final chunk = Uint8List(piece);
          while (true) {
            final got = stream.readInto(chunk, 0, piece);
            if (got <= 0) {
              break;
            }
            read.add(Uint8List.sublistView(chunk, 0, got));
          }
          expect(read.takeBytes(), expanded, reason: '$kind, $piece');
        }
        final stream = file.rawContent!.getStream();
        for (final at in [0, 99, 101, 399, 999, 1003, 1599, 2499, 2549, 2995]) {
          expect(stream.subset(position: at, length: 7).toUint8List(),
              expanded.sublist(at, at + 7 > 3000 ? 3000 : at + 7),
              reason: '$kind, subset $at');
          stream.setPosition(at);
          expect(stream.readBytes(7).toUint8List(),
              expanded.sublist(at, at + 7 > 3000 ? 3000 : at + 7),
              reason: '$kind, readBytes $at');
          stream.setPosition(at);
          expect(stream.readByte(), expanded[at], reason: '$kind, byte $at');
        }
        expect(
            stream
                .subset(position: 900, length: 1000)
                .subset(position: 50, length: 300)
                .toUint8List(),
            expanded.sublist(950, 1250),
            reason: kind);
        stream.setPosition(500);
        expect(stream.toUint8List(), expanded.sublist(500), reason: kind);
        expect(stream.position, 500, reason: kind);
        final zipped =
            ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(archive));
        expect(zipped.single.content, expanded, reason: '$kind zip');
      }
      final out = p.join(directory.path, 'out');
      await extractFileToDisk(path, out);
      expect(File(p.join(out, 'gnu.bin')).readAsBytesSync(), expanded);
      final two = Uint8List.fromList([
        ...bytes.sublist(0, bytes.length - 1024),
        ...TarEncoder().encodeBytes(
            Archive()..add(ArchiveFile.string('after.txt', 'after'))),
      ]);
      final names = <String>[];
      await for (final entry in Stream<List<int>>.fromIterable(
              [two.sublist(0, 700), two.sublist(700, 1500), two.sublist(1500)])
          .transform(tarCodec.decoder)) {
        await entry.writeToFile(p.join(directory.path, 'codec_${entry.name}'));
        expect(() => entry.content, throwsA(isA<StateError>()));
        names.add(entry.name);
      }
      expect(names, ['gnu.bin', 'after.txt']);
      expect(File(p.join(directory.path, 'codec_gnu.bin')).readAsBytesSync(),
          expanded);
      expect(File(p.join(directory.path, 'codec_after.txt')).readAsStringSync(),
          'after');
      final pending = <Future<void>>[];
      await for (final entry in Stream<List<int>>.fromIterable(
              [two.sublist(0, 700), two.sublist(700, 1500), two.sublist(1500)])
          .transform(tarCodec.decoder)) {
        pending.add(
            entry.writeToFile(p.join(directory.path, 'later_${entry.name}')));
      }
      await Future.wait(pending);
      expect(File(p.join(directory.path, 'later_gnu.bin')).readAsBytesSync(),
          expanded);
      expect(File(p.join(directory.path, 'later_after.txt')).readAsStringSync(),
          'after');
      final cut = two.sublist(0, 512 + 600);
      await expectLater(() async {
        await for (final entry
            in Stream<List<int>>.value(cut).transform(tarCodec.decoder)) {
          await entry.writeToFile(p.join(directory.path, 'cut.bin'));
        }
      }, throwsA(isA<ArchiveException>()));
    });

    test('invalid archive', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(TarDecoder().decodeBytes(bytes), isEmpty);
      expect(() => TarDecoder().decodeBytes(bytes, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test('header checksum is checked with verify or throwOnError', () {
      final bytes = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'content')));
      bytes[0] = 98;
      for (final decode in [
        (bool verify, bool throwOnError) => TarDecoder()
            .decodeBytes(bytes, verify: verify, throwOnError: throwOnError),
        (bool verify, bool throwOnError) => TarDecoder().decodeStream(
            InputMemoryStream(bytes),
            verify: verify,
            throwOnError: throwOnError),
      ]) {
        final file = decode(false, false).files.single;
        expect(file.name, 'b.txt');
        expect(file.content, utf8.encode('content'));
        for (final (verify, throwOnError) in [(false, true), (true, true)]) {
          expect(
              () => decode(verify, throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))));
        }
      }
    });

    test('verify with throwOnError rejects missing entry padding', () {
      final bytes = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'data')));
      for (final length in [516, 517, 1023, 1024]) {
        final cut = Uint8List.sublistView(bytes, 0, length);
        expect(TarDecoder().decodeBytes(cut).files.single.content,
            utf8.encode('data'));
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          for (final storeData in [false, true]) {
            final decode = () => TarDecoder().decodeBytes(cut,
                verify: verify,
                throwOnError: throwOnError,
                storeData: storeData);
            expect(
                decode,
                length == 1024
                    ? returnsNormally
                    : throwsA(isA<ArchiveException>()),
                reason: 'length $length verify $verify storeData $storeData');
          }
        }
      }
    });

    test('file', testOn: 'vm', () {
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes('file.txt', [100])));
      File(p.join(testOutputPath, 'tar_encoded.tar'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tar);
    });

    test('file with symlink', testOn: 'vm', () {
      ArchiveFile symlink = ArchiveFile.symlink('file.txt', 'file2.txt');
      final tar = TarEncoder().encodeBytes(Archive()..add(symlink));
      File(p.join(testOutputPath, 'tar_encoded.tar'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(tar);
      final archive = TarDecoder().decodeBytes(tar);
      expect(archive[0].isSymbolicLink, true);
    });

    test('file GNU tar files store extra long file names in a separate file.',
        testOn: 'vm', () {
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

    test('long file name', testOn: 'vm', () {
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

    test('pax header with binary xattr record', testOn: 'vm', () {
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

    test('GNU dumpdir entry is directory', testOn: 'vm', () {
      final file = File('test/_data/tar/gnu-incremental.tar');
      final archive = TarDecoder().decodeBytes(file.readAsBytesSync());
      final dir = archive.findFile('test2/')!;
      expect(dir.isFile, isFalse);
      expect(archive.findFile('test2/foo')!.content.length, 64);
    });

    test('GNU long link name', testOn: 'vm', () {
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

    test('regular file with path ././@LongLink sets only its own long name',
        () async {
      List<int> entry(List<int> name, List<int> data,
          {int mode = 420, String type = TarFile.normalFile, int? size}) {
        final h = Uint8List(512);
        void put(int off, String s) =>
            h.setRange(off, off + s.length, ascii.encode(s));
        h.setRange(0, name.length < 100 ? name.length : 100, name);
        put(100, mode.toRadixString(8).padLeft(7, '0'));
        put(108, '0000000');
        put(116, '0000000');
        put(124, (size ?? data.length).toRadixString(8).padLeft(11, '0'));
        put(136, '00000000000');
        put(148, '        ');
        put(156, type);
        var sum = 0;
        for (final b in h) {
          sum += b;
        }
        put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
        return [...h, ...data, ...Uint8List((512 - data.length % 512) % 512)];
      }

      List<int> record(String keyword, String value) {
        for (var length = keyword.length + value.length + 3;; length++) {
          if ('$length'.length + keyword.length + value.length + 3 == length) {
            return ascii.encode('$length $keyword=$value\n');
          }
        }
      }

      Future<List<String>> both(List<int> tar) async {
        final bytes = Uint8List.fromList([...tar, ...Uint8List(1024)]);
        final decoded = [
          for (final f in TarDecoder().decodeBytes(bytes))
            '${f.name}=${utf8.decode(f.readBytes()!)}'
        ];
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async =>
                '${e.name}=${utf8.decode(await e.content.expand((b) => b).toList())}')
            .toList();
        expect(streamed, decoded);
        return decoded;
      }

      final link = ascii.encode('././@LongLink');
      final victim = entry(ascii.encode('victim.txt'), ascii.encode('hello'));
      for (final target in ['renamed.txt', 'x' * 120]) {
        expect(
            await both(
                [...entry(link, ascii.encode(target), mode: 0), ...victim]),
            ['././@LongLink=$target', 'victim.txt=hello']);
      }
      expect(await both(entry(link, ascii.encode('a' * 120), mode: 0)),
          ['././@LongLink=${'a' * 120}']);

      final long = 'a${'ä' * 70}.txt';
      final encoded = utf8.encode(long);
      expect(
          await both([
            ...entry(link, encoded, mode: 0),
            ...entry(encoded, ascii.encode('hello')),
          ]),
          ['$long=hello']);

      final a = ascii.encode('a' * 120);
      final b = ascii.encode('b' * 120);
      expect(
          await both([
            ...entry(link, a, mode: 0),
            ...entry(link, b, type: TarFile.longName),
            ...entry(b, ascii.encode('hello')),
          ]),
          ['././@LongLink=${'a' * 120}', '${'b' * 120}=hello']);
      expect(
          await both([
            ...entry(link, a, mode: 0),
            ...entry(ascii.encode('PaxHeader/b'), record('path', 'b' * 120),
                type: TarFile.exHeader),
            ...entry(b, ascii.encode('hello')),
          ]),
          ['././@LongLink=${'a' * 120}', '${'b' * 120}=hello']);

      final z = ascii.encode('z' * 120);
      final named = [
        ...entry(ascii.encode('PaxHeader/c'),
            [...record('path', 'correct.txt'), ...record('uid', '77')],
            type: TarFile.exHeader),
        ...entry(link, z),
        ...victim,
      ];
      expect(
          await both(named), ['correct.txt=${'z' * 120}', 'victim.txt=hello']);
      expect(
          TarDecoder()
              .decodeBytes(Uint8List.fromList([...named, ...Uint8List(1024)]))
              .map((f) => f.ownerId),
          [77, 0]);
      expect(
          await both([
            ...entry(ascii.encode('PaxHeader/s'), record('size', '120'),
                type: TarFile.exHeader),
            ...entry(link, z, size: 0),
            ...victim,
          ]),
          ['././@LongLink=${'z' * 120}', 'victim.txt=hello']);
    });

    test(
        'truncated or foreign data throws with verify or throwOnError, not without',
        testOn: 'vm', () {
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', Uint8List(100)))
        ..add(ArchiveFile.bytes('b.txt', Uint8List(5000))));
      final cut = Uint8List.sublistView(tar, 0, 512 + 512 + 512 + 1000);
      expect(TarDecoder().decodeBytes(cut).files.map((f) => f.name),
          contains('a.txt'));
      final zip = File('test/_data/tar/folder.zip').readAsBytesSync();
      for (final bad in [cut, zip]) {
        expect(() => TarDecoder().decodeBytes(bad), returnsNormally);
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => TarDecoder()
                  .decodeBytes(bad, verify: verify, throwOnError: throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))),
              reason: 'verify $verify, throwOnError $throwOnError');
        }
      }
    });

    test(
        'verify with throwOnError rejects truncated end block, as stream '
        'decoder does', () async {
      final tar = TarEncoder().encodeBytes(
          Archive()..add(ArchiveFile.bytes('a.txt', Uint8List(100))));
      final cut = Uint8List.sublistView(tar, 0, 512 + 512 + 100);
      await expectLater(
          Stream<List<int>>.value(cut)
              .transform(tarCodec.decoder)
              .drain<void>(),
          throwsA(isA<ArchiveException>()));
      for (final (verify, throwOnError) in [(true, true), (false, true)]) {
        expect(
            () => TarDecoder()
                .decodeBytes(cut, verify: verify, throwOnError: throwOnError),
            throwsA(isA<ArchiveException>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('empty or 1-byte input throws with throwOnError', () async {
      for (final bytes in [
        <int>[],
        <int>[0]
      ]) {
        expect(TarDecoder().decodeBytes(bytes).files, isEmpty);
        await expectLater(
            Stream<List<int>>.value(bytes)
                .transform(tarCodec.decoder)
                .drain<void>(),
            throwsA(isA<ArchiveException>()),
            reason: '${bytes.length} bytes');
        for (final (verify, throwOnError) in [(true, true), (false, true)]) {
          expect(
              () => TarDecoder().decodeBytes(bytes,
                  verify: verify, throwOnError: throwOnError),
              throwsA(isA<ArchiveException>()),
              reason: '${bytes.length} bytes, verify $verify, '
                  'throwOnError $throwOnError');
        }
      }
    });

    test('callback error is rethrown unchanged', () {
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', Uint8List(100)))
        ..add(ArchiveFile.bytes('b.txt', Uint8List(5000))));
      for (final (verify, throwOnError) in [
        (false, false),
        (true, false),
        (false, true)
      ]) {
        expect(
            () => TarDecoder().decodeBytes(tar,
                verify: verify,
                throwOnError: throwOnError,
                callback: (_) => throw StateError('callback')),
            throwsA(isA<StateError>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('verify with throwOnError rejects what is not a tar', testOn: 'vm',
        () {
      // Without a checksum check nothing tells a tar apart from an unrelated
      // file: every other header field reads as something.
      final zip = File('test/_data/tar/folder.zip').readAsBytesSync();
      expect(
          () => TarDecoder().decodeBytes(zip, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));

      // Every archive the tests carry has to still pass.
      for (final path in Directory('test/_data/tar')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tar'))) {
        expect(
            () => TarDecoder().decodeBytes(path.readAsBytesSync(),
                verify: true, throwOnError: true),
            path.path.endsWith('writer-big.tar')
                ? throwsA(isA<ArchiveException>())
                : returnsNormally,
            reason: path.path);
      }
    });

    test('pax header size, mtime, uid and gid records', testOn: 'vm', () {
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

    test('pax size decodes as libarchive decodes it', () async {
      Uint8List archive(String size) {
        final records = utf8.encode(_paxRecord('size', size));
        return Uint8List.fromList([
          ..._tarHeader('PaxHeaders/a', 'x', records.length,
              magic: 'ustar\u000000'),
          ..._tarBlocks(records),
          ..._tarHeader('a', '0', 0, magic: 'ustar\u000000'),
          ..._tarBlocks([0x61, 0x61, 0x61]),
          ...Uint8List(1024),
        ]);
      }

      for (final size in [' 3', '\t3xyz', '3 ']) {
        final bytes = archive(size);
        expect(TarDecoder().decodeBytes(bytes, verify: true)[0].content,
            [0x61, 0x61, 0x61],
            reason: size);
        final streamed = await Stream<List<int>>.value(bytes)
            .transform(tarCodec.decoder)
            .asyncMap((e) async => await e.content.expand((b) => b).toList())
            .toList();
        expect(
            streamed,
            [
              [0x61, 0x61, 0x61]
            ],
            reason: size);
      }
      for (final size in [
        '-19769411113659727436',
        '-3',
        '99999999999999999999',
        '${'0' * 64}3',
      ]) {
        final bytes = archive(size);
        expect(TarDecoder().decodeBytes(bytes).files, isEmpty, reason: size);
        expect(
            () => TarDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: size);
        expect(() => TarDecoder().decodeBytes(bytes, throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: size);
        expect(
            Stream<List<int>>.value(bytes).transform(tarCodec.decoder).toList(),
            throwsA(isA<ArchiveException>()),
            reason: size);
      }
    });

    test('pax mtime, uid and gid decode as libarchive decodes them', () async {
      Uint8List archive(String key, String value) {
        final records = utf8.encode(_paxRecord(key, value));
        return Uint8List.fromList([
          ..._tarHeader('PaxHeaders/a', 'x', records.length,
              magic: 'ustar\u000000'),
          ..._tarBlocks(records),
          ..._tarHeader('a', '0', 0, magic: 'ustar\u000000', fields: const {
            108: '0000007\u0000',
            116: '0000011\u0000',
            136: '00000000144\u0000',
          }),
          ...Uint8List(1024),
        ]);
      }

      const keys = ['mtime', 'uid', 'gid'];
      for (final (key, value, expected) in [
        ('mtime', '1748089464', 1748089464),
        ('mtime', '1748089464.951928467', 1748089464),
        ('mtime', '123.', 123),
        ('mtime', '-5', -5),
        ('mtime', '1748089464.951928467a', 100),
        ('mtime', '+5', 100),
        ('mtime', ' 123', 100),
        ('mtime', '1e3', 100),
        ('mtime', '', 100),
        ('mtime', '99999999999999999999', 100),
        ('uid', ' 77', 77),
        ('uid', '77xyz', 77),
        ('uid', '-1', 7),
        ('uid', '', 7),
        ('uid', '99999999999999999999', 7),
        ('gid', '\t88', 88),
        ('gid', '-1', 9),
      ]) {
        final fields = [100, 7, 9]..[keys.indexOf(key)] = expected;
        final bytes = archive(key, value);
        final file = TarDecoder().decodeBytes(bytes, verify: true)[0];
        expect([file.lastModTime, file.ownerId, file.groupId], fields,
            reason: '$key=$value');
        final entry = (await Stream<List<int>>.value(bytes)
                .transform(tarCodec.decoder)
                .toList())
            .single;
        expect([entry.lastModTime, entry.ownerId, entry.groupId], fields,
            reason: '$key=$value');
      }
      for (final (key, value) in [
        ('mtime', '1' * 129),
        ('uid', '1' * 65),
        ('gid', '1' * 65),
      ]) {
        final bytes = archive(key, value);
        expect(TarDecoder().decodeBytes(bytes).files, isEmpty, reason: key);
        expect(
            () => TarDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()),
            reason: key);
        expect(
            Stream<List<int>>.value(bytes).transform(tarCodec.decoder).toList(),
            throwsA(isA<ArchiveException>()),
            reason: key);
      }
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

    test('v7 entry with trailing slash decodes as directory', () async {
      Uint8List header(String name, int size) {
        final h = Uint8List(512);
        void put(int off, String s) =>
            h.setRange(off, off + s.length, ascii.encode(s));
        put(0, name);
        put(100, '0000755');
        put(108, '0000000');
        put(116, '0000000');
        put(124, size.toRadixString(8).padLeft(11, '0'));
        put(136, '00000000000');
        put(148, '        ');
        var sum = 0;
        for (final b in h) {
          sum += b;
        }
        put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
        return h;
      }

      final content = ascii.encode('inside');
      final bytes = Uint8List.fromList([
        ...header('dir/', 0),
        ...header('dir/a.txt', content.length),
        ...content,
        ...Uint8List(512 - content.length),
        ...Uint8List(1024),
      ]);

      final archive = TarDecoder().decodeBytes(bytes);
      expect(archive.findFile('dir/')!.isFile, isFalse);
      expect(archive.findFile('dir/a.txt')!.isFile, isTrue);

      final entries = await Stream<List<int>>.value(bytes)
          .transform(tarCodec.decoder)
          .asyncMap((e) async {
        await e.content.drain<void>();
        return '${e.name} ${e.type.name}';
      }).toList();
      expect(entries, ['dir/ directory', 'dir/a.txt file']);
    });

    test('v7 directory with nonzero size has no content blocks', () async {
      Uint8List header(String name, int size, [String typeFlag = '']) {
        final h = Uint8List(512);
        void put(int off, String s) =>
            h.setRange(off, off + s.length, ascii.encode(s));
        put(0, name);
        put(100, '0000755');
        put(108, '0000000');
        put(116, '0000000');
        put(124, size.toRadixString(8).padLeft(11, '0'));
        put(136, '00000000000');
        put(148, '        ');
        put(156, typeFlag);
        var sum = 0;
        for (final b in h) {
          sum += b;
        }
        put(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
        return h;
      }

      final path = ascii.encode('14 path=long/\n');
      final bytes = Uint8List.fromList([
        ...header('directory1/', 1),
        ...header('directory2/', 0),
        ...header('PaxHeader', path.length, TarFile.exHeader),
        ...path,
        ...Uint8List(512 - path.length),
        ...header('short', 1),
        ...header('file.txt', 0),
        ...Uint8List(1024),
      ]);
      const names = ['directory1/', 'directory2/', 'long/', 'file.txt'];

      final archive = TarDecoder().decodeBytes(bytes);
      expect(archive.map((file) => file.name), names);
      expect(archive.map((file) => file.isFile), [false, false, false, true]);
      expect(TarDecoder().decodeBytes(bytes, verify: true).length, 4);

      final entries = await Stream<List<int>>.value(bytes)
          .transform(tarCodec.decoder)
          .asyncMap((e) async {
        await e.content.drain<void>();
        return e.name;
      }).toList();
      expect(entries, names);
    });

    test('pax path with invalid UTF-8 keeps its bytes', () async {
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

      List<int> entry(List<int> path) {
        final record = [...ascii.encode('${path.length + 9} path='), ...path];
        return [
          ...header('PaxHeader', record.length + 1, TarFile.exHeader),
          ...record,
          0x0a,
          ...Uint8List(511 - record.length),
          ...header('short', 0, TarFile.normalFile),
        ];
      }

      const damaged = [0x61, 0xcc, 0x8c, 0x6d, 0xfc, 0x78];
      final bytes = Uint8List.fromList([
        ...entry(damaged),
        ...entry(utf8.encode('päth')),
        ...Uint8List(1024),
      ]);
      final names = [String.fromCharCodes(damaged), 'päth'];

      final archive = TarDecoder().decodeBytes(bytes);
      expect(archive.map((file) => file.name), names);

      final entries = await Stream<List<int>>.value(bytes)
          .transform(tarCodec.decoder)
          .map((e) => e.name)
          .toList();
      expect(entries, names);
    });

    test('pax header without storing data', testOn: 'vm', () {
      // The pax header's own content has to be read even when file data is
      // being skipped, since it carries the next entry's name.
      final file = File('test/_data/tar/pax.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, storeData: false);

      expect(archive.length, equals(2));
      expect(archive[0].name, equals('a/${_paxLongName}'));
      expect(archive[1].symbolicLink, equals(_paxLongName));
    });

    test('base 256 encoded header fields', testOn: 'vm', () {
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
      void seal(Uint8List header) {
        header.fillRange(148, 156, 0x20);
        var sum = 0;
        for (var i = 0; i < 512; i++) {
          sum += header[i];
        }
        header.setRange(
            148, 156, '${sum.toRadixString(8).padLeft(6, '0')}\x00 '.codeUnits);
      }

      final tooWide = Uint8List(1024);
      tooWide.setRange(0, 5, 'a.txt'.codeUnits);
      tooWide.setRange(124, 136, [0x80, 0x7f, ...List.filled(10, 0xff)]);
      tooWide[156] = 0x30;
      tooWide.setRange(257, 263, 'ustar '.codeUnits);
      seal(tooWide);
      expect(TarDecoder().decodeBytes(tooWide).files, isEmpty);
      expect(() => TarDecoder().decodeBytes(tooWide, throwOnError: true),
          throwsA(isA<ArchiveException>()));

      // The encoding can express a negative number, which no size can be.
      final header = Uint8List(1024);
      header.setRange(0, 5, 'a.txt'.codeUnits);
      header.fillRange(124, 136, 0xff);
      header[156] = 0x30; // normal file
      header.setRange(257, 263, 'ustar '.codeUnits);
      seal(header);
      expect(TarDecoder().decodeBytes(header).files, isEmpty);
      expect(() => TarDecoder().decodeBytes(header, throwOnError: true),
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
      tooWide.ownerId = 4611686018427387904;
      expect(() => TarEncoder().encodeBytes(Archive()..add(tooWide)),
          throwsA(isA<ArchiveException>()));

      // As is anything the decoder would refuse to read back: it stops at
      // 2^53-1, the widest integer that is exact on every platform
      final unreadable = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      unreadable.ownerId = 9007199254740992;
      expect(() => TarEncoder().encodeBytes(Archive()..add(unreadable)),
          throwsA(isA<ArchiveException>()));
      final widestExact = ArchiveFile.bytes('a.txt', Uint8List.fromList([1]));
      widestExact.ownerId = (9007199254740992) - 1;
      widestExact.groupId = -(9007199254740992);
      final exact = TarEncoder().encodeBytes(Archive()..add(widestExact));
      expect(TarDecoder().decodeBytes(exact, verify: true)[0].ownerId,
          equals((9007199254740992) - 1));
      expect(TarDecoder().decodeBytes(exact, verify: true)[0].groupId,
          equals(-(9007199254740992)));
    });

    test('an entry given as a stream is not pulled into memory to encode',
        testOn: 'vm', () {
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

    test('encoding a stream entry leaves its stream where it was', testOn: 'vm',
        () {
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
        // With verify and throwOnError only zeros may follow last entry
        expect(
            () => TarDecoder()
                .decodeBytes(junk, verify: true, throwOnError: true),
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

    test('non-ASCII name and link target are written as pax records', () {
      final name = 'unicode/Größe ${'é' * 80}.txt';
      const target = 'unicode/ünïcödé.txt';
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.symlink(name, target))
        ..add(ArchiveFile.string('plain.txt', 'plain')));
      expect(String.fromCharCode(tar[156]), equals(TarFile.exHeader));
      final records = utf8.decode(tar.sublist(512, 1024)).split('\n');
      expect(records, contains(endsWith(' path=$name')));
      expect(records, contains(endsWith(' linkpath=$target')));
      for (final record in records.where((r) => r.contains('='))) {
        expect(int.parse(record.split(' ').first),
            utf8.encode('$record\n').length);
      }
      final back = TarDecoder().decodeBytes(tar, verify: true);
      expect(back[0].name, equals(name));
      expect(back[0].symbolicLink, equals(target));
      expect(back[1].name, equals('plain.txt'));
      expect(String.fromCharCode(tar[512 + 512 + 512 + 156]),
          equals(TarFile.normalFile));
    });

    test(
        'verify with throwOnError rejects a damaged header that starts with '
        'zeros', () {
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
        expect(
            () => TarDecoder()
                .decodeBytes(damaged, verify: true, throwOnError: true),
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

    test('long file name not null terminated', testOn: 'vm', () {
      final bytes = File('test/_data/tar/firebase_messaging-10.0.8.tar.gz')
          .readAsBytesSync();
      final tarBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      final archive = TarDecoder().decodeBytes(tarBytes, verify: true);
      expect(archive.length, equals(129));
      expect(
          archive[13].name,
          equals(
              'android/src/main/java/io/flutter/plugins/firebase/messaging/FlutterFirebaseMessagingBackgroundExecutor.java'));
    });

    test('symlink', testOn: 'vm', () {
      var file = File('test/_data/tar/symlink_tar.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(4));
      expect(archive[1].isSymbolicLink, equals(true));
      expect(archive[1].symbolicLink, equals('b/b.txt'));
    });

    test('decode test2.tar', testOn: 'vm', () {
      final file = File('test/_data/test2.tar');
      final bytes = file.readAsBytesSync();
      final archive = TarDecoder().decodeBytes(bytes, verify: true);

      final expectedFiles = <File>[];
      listDir(expectedFiles, Directory('test/_data/test2'));

      expect(archive.length, equals(4));
    });

    test('decode test2.tar.gz', testOn: 'vm', () {
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
      test('untar ${t['file']}', testOn: 'vm', () {
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
Uint8List _tarHeader(String name, String type, int size,
    {String link = '', String magic = '', Map<int, String> fields = const {}}) {
  final header = Uint8List(512);
  void put(int at, String value) =>
      header.setRange(at, at + value.length, latin1.encode(value));
  put(0, name);
  put(100, '0000644\u0000');
  put(108, '0000000\u0000');
  put(116, '0000000\u0000');
  put(124, '${size.toRadixString(8).padLeft(11, '0')}\u0000');
  put(136, '00000000000\u0000');
  put(156, type);
  put(157, link);
  put(257, magic);
  fields.forEach(put);
  put(148, '        ');
  final sum = header.fold<int>(0, (a, b) => a + b);
  put(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  return header;
}

Uint8List _tarBlocks(List<int> data) =>
    Uint8List((data.length + 511) & ~511)..setRange(0, data.length, data);

String _paxRecord(String key, String value) {
  final line = ' $key=$value\n';
  var length = line.length + 1;
  while ('$length$line'.length != length) {
    length++;
  }
  return '$length$line';
}

class _RefusesBulkRead extends InputMemoryStream {
  _RefusesBulkRead(super.bytes);

  @override
  Uint8List toUint8List() => throw StateError('entry pulled into memory');
}

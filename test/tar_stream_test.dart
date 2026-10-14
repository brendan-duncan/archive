import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// tar has no index at the end and no back references, so it goes both ways in
// a stream. Writing: the bytes have to be the ones the whole-archive encoder
// writes, and nesting it in a codec's sink has to compress on the way past.
// Reading: the same entries the whole-archive decoder finds, whatever the
// input is cut into.

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state =
        (state * 20077 + state * 16838 % 0x8000 * 0x10000 + 12345) % 0x80000000;
    bytes[i] = (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

// lastModTime takes DateTime.now() on first read, so two lists encoded in
// different seconds gave different tars, and each entry gets fixed time
List<ArchiveFile> _entries() => [
      ArchiveFile.string('readme.txt', 'the first entry')
        ..lastModTime = 1700000000,
      ArchiveFile.bytes('binary.dat', _source(70000, 3))
        ..lastModTime = 1700000000,
      ArchiveFile.bytes('small.dat', _source(7, 5))..lastModTime = 1700000000,
      ArchiveFile.bytes('again.dat', _source(200000, 9))
        ..lastModTime = 1700000000,
    ];

Archive _archiveOf(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return archive;
}

Uint8List _tar(List<ArchiveFile> entries) {
  final held = _Held();
  final encoder = TarChunkedEncoder(held);
  for (final entry in entries) {
    encoder.add(entry);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

Uint8List _paxSparse(String map, int dataLength) {
  String record(String key, String value) {
    final line = ' $key=$value\n';
    var length = line.length + 1;
    while ('$length$line'.length != length) {
      length = '$length$line'.length;
    }
    return '$length$line';
  }

  final records = utf8.encode([
    record('GNU.sparse.major', '1'),
    record('GNU.sparse.minor', '0'),
    record('GNU.sparse.name', 'pax.bin'),
    record('GNU.sparse.realsize', '2048'),
  ].join());
  final output = OutputMemoryStream();
  (TarFile()
        ..filename = 'PaxHeaders/pax.bin'
        ..typeFlag = TarFile.exHeader
        ..fileSize = records.length
        ..contentBytes = Uint8List.fromList(records))
      .write(output);
  final mapBlocks = (map.length + 511) & ~511;
  final data = Uint8List(dataLength)
    ..setRange(0, map.length, ascii.encode(map))
    ..fillRange(mapBlocks, dataLength, 0x61);
  (TarFile()
        ..filename = 'GNUSparseFile.0/pax.bin'
        ..fileSize = data.length
        ..contentBytes = data)
      .write(output);
  return output.getBytes();
}

// Old GNU sparse map has no length field, so only isextended byte of each
// extension block ends it
Uint8List _oldGnuSparse(int blocks) {
  void octal(Uint8List block, int at, int width, int value) => block.setRange(
      at,
      at + width,
      ascii.encode('${value.toRadixString(8).padLeft(width - 1, '0')}\u0000'));
  final header = Uint8List(512)..[0] = 0x66;
  octal(header, 100, 8, 420);
  octal(header, 108, 8, 0);
  octal(header, 116, 8, 0);
  octal(header, 124, 12, 1);
  octal(header, 136, 12, 0);
  header[156] = 0x53;
  header.setRange(257, 265, ascii.encode('ustar  \u0000'));
  octal(header, 386, 12, 0);
  octal(header, 398, 12, 1);
  header[482] = 1;
  octal(header, 483, 12, 1);
  header.fillRange(148, 156, 0x20);
  final sum = header.fold<int>(0, (a, b) => a + b);
  header.setRange(
      148, 156, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\u0000 '));
  final output = BytesBuilder()..add(header);
  for (var i = 0; i < blocks; i++) {
    output.add(Uint8List(512)..[504] = i < blocks - 1 ? 1 : 0);
  }
  output
    ..add(Uint8List(512)..[0] = 0x61)
    ..add(Uint8List(1024));
  return output.takeBytes();
}

Stream<List<int>> _pieces(Uint8List bytes, int piece) async* {
  for (var at = 0; at < bytes.length; at += piece) {
    final end = at + piece < bytes.length ? at + piece : bytes.length;
    yield Uint8List.sublistView(bytes, at, end);
  }
}

/// Name, size and content of every entry, as nested lists: a record of a
/// `Uint8List` compares by identity, which would pass nothing
Future<List<List<Object>>> _stream(Uint8List archive, int piece) async {
  final held = <List<Object>>[];
  await for (final entry
      in _pieces(archive, piece).transform(tarCodec.decoder)) {
    final bytes = <int>[];
    var length = 0;
    var crc = 0;
    await for (final part in entry.content) {
      length += part.length;
      crc = getCrc32(part, crc);
      if (length <= _heldContent) {
        bytes.addAll(part);
      }
    }
    held.add(entry.isDirectory
        ? [entry.name, 0, <int>[]]
        : [
            entry.name,
            entry.size,
            length <= _heldContent ? bytes : '$length bytes, CRC32 $crc'
          ]);
  }
  return held;
}

const _heldContent = 1 << 20;

void main() {
  group('tar chunked encoder', () {
    test('output equals TarEncoder.encodeBytes output', () {
      expect(
          _tar(_entries()), TarEncoder().encodeBytes(_archiveOf(_entries())));
    });

    test('empty archive writes valid tar', () {
      final held = _Held();
      TarChunkedEncoder(held).close();
      expect(held.bytes, TarEncoder().encodeBytes(Archive()));
      expect(TarDecoder().decodeBytes(held.bytes).files, isEmpty);
    });

    test('name longer than header field decodes back', () {
      final name = '${'a-very-long-directory-name/' * 6}file.txt';
      expect(name.length, greaterThan(100));
      final entry = ArchiveFile.string(name, 'content');
      final back = TarDecoder().decodeBytes(_tar([entry]));
      expect(back.files.single.name, name);
    });

    test('add after close throws StateError', () {
      final encoder = TarChunkedEncoder(_Held())..close();
      expect(() => encoder.add(ArchiveFile.string('a', 'b')),
          throwsA(isA<StateError>()));
    });

    test('encoder nested in zstd sink writes .tar.zst while adding', () {
      final entries = _entries();
      final held = _Held();
      final encoder = TarChunkedEncoder(ZstdChunkedEncoder(held, level: 3));
      for (final entry in entries) {
        encoder.add(entry);
      }
      encoder.close();
      expect(held.closed, isTrue);
      final tar = ZstdDecoder()
          .decodeBytes(held.bytes, verify: true, throwOnError: true);
      expect(tar, _tar(entries));
      final back = TarDecoder().decodeBytes(tar);
      expect(back.files.map((f) => f.name), entries.map((e) => e.name));
      expect(back.files[1].content, entries[1].content);
    });

    test('encoder nested in bzip2 sink writes .tar.bz2 while adding', () {
      final entries = _entries();
      final held = _Held();
      final encoder = TarChunkedEncoder(BZip2ChunkedEncoder(held));
      for (final entry in entries) {
        encoder.add(entry);
      }
      encoder.close();
      final tar = BZip2Decoder().decodeBytes(held.bytes, verify: true);
      expect(tar, _tar(entries));
      expect(TarDecoder().decodeBytes(tar).files.map((f) => f.name),
          entries.map((e) => e.name));
    });
  });

  group('tar codec', () {
    test('filenameEncoding is used when encoding and decoding', () async {
      const codec = TarCodec(filenameEncoding: latin1);
      final entries =
          await Stream.value(ArchiveFile.string('caf\u00e9.txt', 'x'))
              .transform(codec.encoder)
              .transform(codec.decoder)
              .toList();
      expect(entries.single.name, 'caf\u00e9.txt');
    });

    test('filenameEncoding decodes long name back', () async {
      const codec = TarCodec(filenameEncoding: latin1);
      final name = '\u00c3\u00a9${'x' * 120}.txt';
      final entries = await Stream.value(ArchiveFile.string(name, 'x'))
          .transform(codec.encoder)
          .transform(codec.decoder)
          .toList();
      expect(entries.single.name, name);
    });

    test('name that filenameEncoding cannot encode decodes back', () async {
      const codec = TarCodec(filenameEncoding: latin1);
      const name = 'price€.txt';
      final entries = await Stream.value(ArchiveFile.string(name, 'x'))
          .transform(codec.encoder)
          .transform(codec.decoder)
          .toList();
      expect(entries.single.name, name);
    });

    test('encoder sends first bytes before reading whole entry', () async {
      final bytes = Uint8List(1024 * 1024);
      var read = 0;
      final input = _ObservedInput(bytes, (count) => read += count);
      final file = ArchiveFile.stream('a', input);
      final first = await Stream.value(file).transform(tarCodec.encoder).first;
      expect(first, isNotEmpty);
      expect(read, lessThan(bytes.length));
    });

    test('entries transform into archive equal to TarEncoder output', () async {
      final entries = _entries();
      final bytes = await Stream.fromIterable(entries)
          .transform(tarCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(bytes, _tar(entries));
    });

    test('entry bytes are unchanged after encode and decode transformers',
        () async {
      // By default the entry is left alone, so the same archive can be written
      // again
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'hello'));
      Future<List<int>> once() => Stream.fromIterable(archive.files)
          .transform(tarCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final first = await once();
      expect(archive.files.single.content, 'hello'.codeUnits);
      expect(await once(), first);
    });

    test('.tar.zst encodes and decodes through one transform chain', () async {
      final entries = _entries();
      final archive = await Stream.fromIterable(entries)
          .transform(tarCodec.encoder)
          .transform(zstdCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final names = <String>[];
      await for (final entry in Stream.fromIterable([archive])
          .transform(zstdCodec.decoder)
          .transform(tarCodec.decoder)) {
        names.add(entry.name);
        await entry.content.drain<void>();
      }
      expect(names, entries.map((e) => e.name));
    });
  });

  group('SinkOutputStream.writeStream', () {
    test('writeStream writes in pieces and keeps input position', () {
      final source = _source(200000, 17);
      final held = _Held();
      final out = SinkOutputStream(held);
      final input = InputMemoryStream(source);
      input.skip(10);
      out.writeStream(input);
      // What is queued is handed over on flush, which every codec calls
      out.flush();
      expect(held.bytes, Uint8List.sublistView(source, 10));
      expect(out.written, source.length - 10);
      expect(input.position, 10);
      expect(held.pieces, greaterThan(1));
    });

    test('single bytes are buffered, not sent to sink one by one', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      for (var i = 0; i < 200000; i++) {
        out.writeByte(i & 0xff);
      }
      out.flush();
      expect(out.written, 200000);
      expect(held.bytes.length, 200000);
      // 64 KiB a piece, not one call per byte
      expect(held.pieces, lessThan(8));
    });

    test('writeStream of exhausted stream writes nothing', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      out.writeStream(InputMemoryStream(Uint8List(0)));
      out.flush();
      expect(out.written, 0);
      expect(held.pieces, 0);
    });
  });

  group('tar stream reader', () {
    test(
        'header checksum failure throws ArchiveException, not ArchiveChecksumException',
        () async {
      final bytes = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'content')));
      bytes[0] = 98;
      await expectLater(
          _stream(bytes, 13),
          throwsA(allOf(isA<ArchiveException>(),
              isNot(isA<ArchiveChecksumException>()))));
    });

    test('corrupted size field throws instead of losing content', () async {
      final archive = Archive()..add(ArchiveFile.string('a', 'abcdef'));
      final bytes = TarEncoder().encodeBytes(archive)..[134] = 0x31;
      expect(
          () =>
              TarDecoder().decodeBytes(bytes, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      await expectLater(_stream(bytes, 512), throwsA(isA<ArchiveException>()));
    });

    test('size field that is not a number throws with a valid checksum',
        () async {
      final empty = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a', '')))
          .sublist(0, 512)
        ..setRange(124, 136, ascii.encode('zzzzzzzzzzz\x00'))
        ..setRange(148, 156, ascii.encode('        '));
      final sum = empty.fold<int>(0, (a, b) => a + b);
      empty.setRange(148, 156,
          ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
      final bytes = Uint8List.fromList([
        ...empty,
        ...TarEncoder()
            .encodeBytes(Archive()..add(ArchiveFile.string('b', 'abcdef'))),
      ]);
      expect(
          () =>
              TarDecoder().decodeBytes(bytes, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      await expectLater(_stream(bytes, 512), throwsA(isA<ArchiveException>()));
    });

    test('pax record length past metadata end throws ArchiveException',
        () async {
      final output = OutputMemoryStream();
      final records = Uint8List.fromList(
          utf8.encode('12 path=foo\n9223372036854775807 path=bar\n'));
      (TarFile()
            ..filename = 'PaxHeader'
            ..typeFlag = TarFile.exHeader
            ..fileSize = records.length
            ..contentBytes = records)
          .write(output);
      (TarFile()
            ..filename = 'entry'
            ..fileSize = 1
            ..contentBytes = Uint8List.fromList([42]))
          .write(output);
      output.writeBytes(Uint8List(1024));
      final bytes = output.getBytes();
      for (final piece in [1, 509, 4096]) {
        expect(await _stream(bytes, piece), [
          [
            'foo',
            1,
            [42]
          ]
        ]);
      }
      for (final flags in [(false, false), (false, true), (true, false)]) {
        final file = TarDecoder()
            .decodeBytes(bytes, verify: flags.$1, throwOnError: flags.$2)
            .files
            .single;
        expect(file.name, 'foo');
        expect(file.content, [42]);
      }
    });

    test('long name and pax header decode through stream', () async {
      final long = '${'a-very-long-directory-name/' * 6}file.txt';
      final entries = [
        ArchiveFile.string(long, 'first'),
        ArchiveFile.bytes('plain.bin', _source(3000, 5)),
      ];
      final archive = Archive();
      for (final entry in entries) {
        archive.add(entry);
      }
      final bytes = TarEncoder().encodeBytes(archive);
      for (final piece in [1, 512, 9999]) {
        final read = await _stream(bytes, piece);
        expect(read.map((e) => e[0]), [long, 'plain.bin'],
            reason: 'piece $piece');
        expect(read[1][2], _source(3000, 5), reason: 'piece $piece');
      }
    });

    test('unread content is skipped, next entry decodes', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(5000, 7)))
        ..add(ArchiveFile.bytes('b.bin', _source(9000, 11)));
      final bytes = TarEncoder().encodeBytes(archive);
      final names = <String>[];
      await for (final entry
          in _pieces(bytes, 333).transform(tarCodec.decoder)) {
        names.add(entry.name);
      }
      expect(names, ['a.bin', 'b.bin']);
    });

    test('partly read content does not break next entry', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(5000, 13)))
        ..add(ArchiveFile.string('b.txt', 'second'));
      final bytes = TarEncoder().encodeBytes(archive);
      final names = <String>[];
      await for (final entry
          in _pieces(bytes, 700).transform(tarCodec.decoder)) {
        names.add(entry.name);
        if (entry.name == 'a.bin') {
          // One piece, then walk away from the rest
          await entry.content.first;
        }
      }
      expect(names, ['a.bin', 'b.txt']);
    });

    test('second read of content throws StateError', () async {
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'one'));
      final bytes = TarEncoder().encodeBytes(archive);
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        await entry.content.drain<void>();
        expect(() => entry.content, throwsA(isA<StateError>()));
      }
    });

    test('content of passed entry throws StateError', () async {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'one'))
        ..add(ArchiveFile.string('b.txt', 'two'));
      final bytes = TarEncoder().encodeBytes(archive);
      final held = <TarEntry>[];
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        held.add(entry);
      }
      expect(() => held.first.content, throwsA(isA<StateError>()));
    });

    test('truncated archive throws ArchiveException', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(4000, 17)));
      final bytes = TarEncoder().encodeBytes(archive);
      final short = Uint8List.sublistView(bytes, 0, 1200);
      expect(_stream(short, 256), throwsA(isA<ArchiveException>()));
    });

    test('pax sparse entry cut inside its map block follows decoder flags', () {
      final whole = _paxSparse('1\n0\n512\n', 1024);
      final cut = Uint8List.sublistView(whole, 0, whole.length - 1024 + 100);
      expect(() => TarDecoder().decodeBytes(cut), returnsNormally);
      for (final (verify, throwOnError) in [(true, true), (false, true)]) {
        expect(
            () => TarDecoder()
                .decodeBytes(cut, verify: verify, throwOnError: throwOnError),
            throwsA(isA<ArchiveException>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('pax sparse entry cut before its map ends follows decoder flags', () {
      final map = StringBuffer('100\n');
      for (var i = 0; i < 100; i++) {
        map.write('${i * 2}\n1\n');
      }
      final whole = _paxSparse(map.toString(), 1124);
      final cut = Uint8List.sublistView(whole, 0, whole.length - 1536 + 100);
      expect(() => TarDecoder().decodeBytes(cut), returnsNormally);
      for (final (verify, throwOnError) in [(true, true), (false, true)]) {
        expect(
            () => TarDecoder()
                .decodeBytes(cut, verify: verify, throwOnError: throwOnError),
            throwsA(isA<ArchiveException>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('source error reaches entry content unchanged', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(4000, 19)));
      final bytes = TarEncoder().encodeBytes(archive);
      Future<Object?> contentError(Stream<List<int>> source) async {
        Object? seen;
        try {
          await for (final entry in source.transform(tarCodec.decoder)) {
            try {
              await entry.content.drain<void>();
            } catch (error) {
              seen = error;
            }
          }
        } catch (_) {}
        return seen;
      }

      final failure = StateError('source failed');
      Stream<List<int>> failing() async* {
        yield Uint8List.sublistView(bytes, 0, 1200);
        throw failure;
      }

      expect(await contentError(failing()), same(failure));

      final large = Archive()
        ..add(ArchiveFile.bytes('b.bin', _source(400000, 23)));
      final xz = XZEncoder().encodeBytes(TarEncoder().encodeBytes(large));
      final cut = Uint8List.sublistView(xz, 0, xz.length ~/ 2);
      expect(
          await contentError(
              Stream<List<int>>.value(cut).transform(xzCodec.decoder)),
          isA<ArchiveException>());
    });

    test('type flag decodes to TarEntryType', () async {
      final archive = Archive()
        ..add(ArchiveFile.directory('dir'))
        ..add(ArchiveFile.string('dir/a.txt', 'one'))
        ..add(ArchiveFile.symlink('link', 'dir/a.txt'));
      final bytes = TarEncoder().encodeBytes(archive);
      final types = <String, TarEntryType>{};
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        types[entry.name] = entry.type;
        await entry.content.drain<void>();
      }
      expect(types['dir'], TarEntryType.directory);
      expect(types['dir/a.txt'], TarEntryType.file);
      expect(types['link'], TarEntryType.symbolicLink);
      expect(types['link'] == TarEntryType.file, isFalse);
    });

    test('only link entries have symbolicLink, as TarDecoder reports',
        () async {
      final archive = Archive()
        ..add(ArchiveFile.directory('dir'))
        ..add(ArchiveFile.string('dir/a.txt', 'one'))
        ..add(ArchiveFile.symlink('link', 'dir/a.txt'));
      final bytes = TarEncoder().encodeBytes(archive);
      final links = <String, String?>{};
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        links[entry.name] = entry.symbolicLink;
        await entry.content.drain<void>();
      }
      final whole = {
        for (final file in TarDecoder().decodeBytes(bytes).files)
          file.name: file.symbolicLink,
      };
      expect(links, whole);
    });

    test('hard link target is relative to link folder, as TarDecoder reports',
        () async {
      final archive = Archive()
        ..add(ArchiveFile.directory('dir'))
        ..add(ArchiveFile.string('dir/a.txt', 'one'))
        ..add(ArchiveFile.symlink('dir/b.txt', 'a.txt')..isHardLink = true);
      final bytes = TarEncoder().encodeBytes(archive);
      final links = <String, String?>{};
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        links[entry.name] = entry.symbolicLink;
        await entry.content.drain<void>();
      }
      final whole = {
        for (final file in TarDecoder().decodeBytes(bytes).files)
          file.name: file.symbolicLink,
      };
      expect(whole['dir/b.txt'], 'a.txt');
      expect(links, whole);
    });

    test('empty archive gives no entries', () async {
      final bytes = TarEncoder().encodeBytes(Archive());
      expect(await _stream(bytes, 512), isEmpty);
    });

    test('reads .tar.zst piece by piece through zstdCodec.decoder', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('big.bin', _source(300000, 23)));
      final tar = TarEncoder().encodeBytes(archive);
      final zst = Uint8List.fromList(zstdCodec.encode(tar));
      final read = <String>[];
      await for (final entry in _pieces(zst, 8192)
          .transform(zstdCodec.decoder)
          .transform(tarCodec.decoder)) {
        read.add(entry.name);
        expect(
            await entry.content.fold<int>(0, (n, p) => n + p.length), 300000);
      }
      expect(read, ['big.bin']);
    });

    test('content listened after reader moved on throws StateError', () async {
      // The skip past an entry empties it, so a late listener used to read
      // nothing and no error
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', _source(1000, 3)))
        ..add(ArchiveFile.bytes('b.txt', _source(10, 5))));
      final contents = <Stream<List<int>>>[];
      await for (final entry
          in Stream<List<int>>.value(tar).transform(tarCodec.decoder)) {
        contents.add(entry.content);
      }
      expect(contents, hasLength(2));
      for (final content in contents) {
        await expectLater(content.drain<void>(), throwsStateError);
      }
    });

    // An input may go silent without closing, a stalled download being the
    // usual one. Neither a cancel nor a timeout may then wait on it for good
    test('cancel works while waiting for header from silent input', () async {
      for (final start in [
        <int>[],
        [1, 2, 3]
      ]) {
        final source = StreamController<List<int>>();
        final subscription =
            source.stream.transform(tarCodec.decoder).listen((_) {});
        if (start.isNotEmpty) {
          source.add(start);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await subscription.cancel().timeout(const Duration(seconds: 5));
        expect(source.hasListener, isFalse, reason: '${start.length} bytes');
        await source.close();
      }
    });

    test('timeout on content from silent input ends wait', () async {
      final tar = TarEncoder().encodeBytes(
          Archive()..add(ArchiveFile.bytes('a.bin', _source(3000, 3))));
      final source = StreamController<List<int>>();
      source.add(Uint8List.sublistView(tar, 0, 1000));
      Object? error;
      try {
        await for (final entry in source.stream.transform(tarCodec.decoder)) {
          await entry.content
              .timeout(const Duration(milliseconds: 200))
              .drain<void>();
        }
      } catch (e) {
        error = e;
      }
      expect(error, isA<TimeoutException>());
      expect(source.hasListener, isFalse);
      await source.close();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('cancel of content part way keeps next entry whole', () async {
      final first = _source(200000, 7);
      final second = _source(5000, 9);
      final tar = TarEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('first.bin', first))
        ..add(ArchiveFile.bytes('second.bin', second)));
      final got = <String, List<int>>{};
      await for (final entry
          in _pieces(tar, 4096).transform(tarCodec.decoder)) {
        if (entry.name == 'first.bin') {
          await entry.content.first;
          continue;
        }
        got[entry.name] = await entry.content
            .fold<List<int>>(<int>[], (all, piece) => all..addAll(piece));
      }
      expect(got['second.bin'], second);
    });

    test('cancel of archive releases paused content reader', () async {
      final tar = TarEncoder().encodeBytes(
          Archive()..add(ArchiveFile.bytes('a.bin', _source(3000, 3))));
      final source = StreamController<List<int>>();
      final received = Completer<void>();
      final archiveErrors = <Object>[];
      final contentErrors = <Object>[];
      late StreamSubscription<List<int>> content;
      final archive = source.stream.transform(tarCodec.decoder).listen((entry) {
        content = entry.content.listen((_) {
          content.pause();
          if (!received.isCompleted) {
            received.complete();
          }
        }, onError: contentErrors.add);
      }, onError: archiveErrors.add);
      source.add(tar.sublist(0, 1000));
      await received.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      try {
        expect(archiveErrors, isEmpty);
        expect(contentErrors, isEmpty);
        final cancelled = await archive
            .cancel()
            .then((_) => true)
            .timeout(const Duration(seconds: 5), onTimeout: () => false);
        expect(archiveErrors, isEmpty);
        expect(contentErrors, isEmpty);
        expect(cancelled, isTrue,
            reason: 'cancel must complete without waiting for onDone; '
                'archive errors: $archiveErrors, content errors: $contentErrors');
        expect(source.hasListener, isFalse);
      } finally {
        content.resume();
        await content.cancel();
        await source.close();
      }
    });
  });

  group('tar stream writer', () {
    test('cancel of encoder over silent source releases source', () async {
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(tarCodec.encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(ArchiveFile.bytes('a.bin', _source(3000, 5)));
      await written.future.timeout(const Duration(seconds: 5));
      // Past the last piece of the entry, so it waits on the source
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel().timeout(const Duration(seconds: 5));
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('source error ends archive stream with same error', () async {
      final source = StreamController<ArchiveFile>();
      final events = <String>[];
      final ended = Completer<void>();
      source.stream.transform(tarCodec.encoder).listen(
          (_) => events.add('data'),
          onError: (Object error) => events.add('$error'),
          onDone: ended.complete);
      source.add(ArchiveFile.bytes('a.bin', _source(3000, 5)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      source.addError(StateError('source failed'));
      await ended.future.timeout(const Duration(seconds: 5));
      expect(events.first, 'data');
      final failed = events.indexOf('Bad state: source failed');
      expect(events.sublist(failed), ['Bad state: source failed']);
      expect(source.hasListener, isFalse);
      await source.close();
    });

    for (final autoClose in [false, true]) {
      test('autoClose $autoClose decides whether written entry is closed',
          () async {
        final content = _ClosingInput(_source(300000, 21));
        final bytes = await Stream.value(ArchiveFile.stream('big.bin', content))
            .transform(TarCodec(autoClose: autoClose).encoder)
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        expect(bytes, isNotEmpty);
        expect(content.closed, autoClose);
      });
    }

    test('autoClose closes entry interrupted by cancel', () async {
      final content = _ClosingInput(_source(4 << 20, 23));
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(const TarCodec(autoClose: true).encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(ArchiveFile.stream('big.bin', content));
      await written.future.timeout(const Duration(seconds: 5));
      await subscription.cancel().timeout(const Duration(seconds: 5));
      await source.close();
      expect(content.closed, isTrue);
    });

    // The entry stream reports a length of 0 before its end. Only the first
    // 100 pieces are taken. The whole archive is fewer than 100 pieces
    test('entry whose length disagrees with isEOS ends instead of looping',
        () async {
      final pieces = await Stream.value(
              ArchiveFile.stream('a.bin', _LyingInput(Uint8List(10))))
          .transform(tarCodec.encoder)
          .take(100)
          .toList();
      expect(pieces.length, lessThan(100));
    });
  });

  group('sparse map', () {
    Future<void> refused(Uint8List bytes) async {
      expect(() => TarDecoder().decodeBytes(bytes),
          throwsA(isA<ArchiveLimitException>()));
      await expectLater(
          _pieces(bytes, 4096)
              .transform(tarCodec.decoder)
              .asyncMap((entry) => entry.content.drain<void>())
              .drain<void>(),
          throwsA(isA<ArchiveLimitException>()));
    }

    test('in old GNU extension blocks throws above maxMetadataSize', () async {
      await refused(_oldGnuSparse(TarFile.maxMetadataSize ~/ 512 + 1));
      expect(TarDecoder().decodeBytes(_oldGnuSparse(4)), hasLength(1));
    });

    test('in pax 1.0 entry data throws above maxMetadataSize', () async {
      final count = TarFile.maxMetadataSize ~/ 4 + 1;
      final map = '$count\n${'0\n1\n' * count}';
      await refused(_paxSparse(map, (map.length + 511) & ~511));
    });
  });

  group('declared length does not allocate memory', () {
    test('long name header claiming 1 TB throws without allocating', () async {
      final header = _longLink(1099511627776);
      expect(() => TarDecoder().decodeBytes(header),
          throwsA(isA<ArchiveLimitException>()));
      Object? thrown;
      try {
        await Stream<List<int>>.value(header)
            .transform(tarCodec.decoder)
            .toList();
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArchiveException>());
    });
  });
}

/// A `././@LongLink` header that says it has [size] bytes of content. The
/// content never comes
Uint8List _longLink(int size) {
  final header = Uint8List(512);
  const name = '././@LongLink';
  for (var i = 0; i < name.length; i++) {
    header[i] = name.codeUnitAt(i);
  }
  for (final field in [100, 108, 116]) {
    for (var i = 0; i < 7; i++) {
      header[field + i] = 0x30;
    }
  }
  // The octal size field is too narrow for this, base 256 is not
  header[124] = 0x80;
  var left = size;
  for (var i = 135; i > 124; i--) {
    header[i] = left % 256;
    left ~/= 256;
  }
  for (var i = 0; i < 11; i++) {
    header[136 + i] = 0x30;
  }
  header[156] = 0x4c;
  const magic = 'ustar  ';
  for (var i = 0; i < magic.length; i++) {
    header[257 + i] = magic.codeUnitAt(i);
  }
  for (var i = 0; i < 8; i++) {
    header[148 + i] = 0x20;
  }
  var sum = 0;
  for (final byte in header) {
    sum += byte;
  }
  final octal = sum.toRadixString(8).padLeft(6, '0');
  for (var i = 0; i < 6; i++) {
    header[148 + i] = octal.codeUnitAt(i);
  }
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

class _ObservedInput extends InputMemoryStream {
  final void Function(int) onRead;

  _ObservedInput(super.bytes, this.onRead);

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) {
    final start = position ?? this.position;
    return _ObservedInput(
        Uint8List.sublistView(buffer!, start, start + (length ?? this.length)),
        onRead);
  }

  @override
  int readInto(Uint8List into, int at, int count) {
    final got = super.readInto(into, at, count);
    onRead(got);
    return got;
  }

  // Tar converter reads entry body through readBytes, so counter stayed at 0
  // after full 1 MiB read and let emit test pass without checking anything
  @override
  InputStream readBytes(int count) {
    final got = super.readBytes(count);
    onRead(got.length);
    return got;
  }
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;
  var closed = false;

  int get pieces => _pieces.length;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

/// Reports whether whoever took it closed it
class _ClosingInput extends InputMemoryStream {
  var closed = false;

  _ClosingInput(super.bytes);

  @override
  void closeSync() {
    closed = true;
    super.closeSync();
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

/// Reports a length of 0 while it still holds bytes. Every subset of it does
/// the same. A real InputStream can behave this way
class _LyingInput extends InputMemoryStream {
  final Uint8List bytes;

  _LyingInput(this.bytes) : super(bytes);

  @override
  int get length => 0;

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) =>
      _LyingInput(bytes);
}

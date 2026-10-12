import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

// zip is written forward: a local header, its data, and the central directory
// at the end, nothing read back. So the bytes have to be the ones the
// whole-archive encoder writes, and the archive has to come back off disk
// entry by entry..

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

List<ArchiveFile> _entries() => [
      ArchiveFile.string('readme.txt', 'the first entry'),
      ArchiveFile.bytes('dir/binary.dat', _source(70000, 3)),
      ArchiveFile.bytes('small.dat', _source(7, 5)),
    ]..forEach((entry) => entry.lastModTime = 1700000000);

Archive _archiveOf(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return archive;
}

Uint8List _zip(List<ArchiveFile> entries,
    {int level = DeflateLevel.bestSpeed, bool streamed = true}) {
  final held = _Held();
  final encoder = ZipChunkedEncoder(held, level: level, streamed: streamed);
  for (final entry in entries) {
    encoder.add(entry);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  group('zip chunked encoder', () {
    test('with sizes in local header output equals ZipEncoder.encodeBytes', () {
      final held = OutputMemoryStream();
      ZipEncoder().encodeStream(_archiveOf(_entries()), held);
      expect(_zip(_entries(), streamed: false), held.getBytes());
    });

    test('output decodes back', () {
      // The encoder reads an entry's content, so what it should be has to be
      // held before it goes in
      final want = _source(70000, 3);
      final back = ZipDecoder().decodeBytes(_zip(_entries()), verify: true);
      expect(back.files.map((f) => f.name), _entries().map((e) => e.name));
      expect(back.files[1].content, want);
    });

    test('empty archive writes valid zip', () {
      final held = _Held();
      ZipChunkedEncoder(held).close();
      expect(ZipDecoder().decodeBytes(held.bytes).files, isEmpty);
    });

    test('stored entry above 1 MiB is written in steps', () {
      final data = _source(3 << 20, 9);
      for (final streamed in [false, true]) {
        final held = _Held();
        final encoder = ZipChunkedEncoder(held, streamed: streamed);
        final body = encoder.addHeader(ArchiveFile.bytes('stored.bin', data)
          ..compression = CompressionType.none);
        encoder.flush();
        expect(body, isNotNull, reason: 'streamed $streamed');
        expect(held.bytes.length, lessThan(1 << 16),
            reason: 'streamed $streamed');
        var steps = 0;
        while (body!.step()) {
          steps++;
        }
        body.finish();
        encoder.close();
        expect(steps, greaterThan(1), reason: 'streamed $streamed');
        final back = ZipDecoder().decodeBytes(held.bytes, verify: true);
        expect(back.single.readBytes(), data, reason: 'streamed $streamed');
      }
    });

    test('add after close throws StateError', () {
      final encoder = ZipChunkedEncoder(_Held())..close();
      expect(() => encoder.add(ArchiveFile.string('a', 'b')),
          throwsA(isA<StateError>()));
    });

    test('bytes reach sink as entries are added', testOn: 'vm', () {
      final held = _Held();
      final encoder = ZipChunkedEncoder(held);
      expect(held.pieces, 0);
      encoder.add(ArchiveFile.bytes('a.bin', _source(60000, 7)));
      final afterFirst = held.bytes.length;
      expect(afterFirst, greaterThan(0));
      encoder.add(ArchiveFile.bytes('b.bin', _source(60000, 11)));
      expect(held.bytes.length, greaterThan(afterFirst));
      encoder.close();
    });

    test('with autoClose false same file entry encodes into second archive',
        testOn: 'vm', () {
      final dir = Directory.systemTemp.createTempSync('zip_reuse');
      addTearDown(() => dir.deleteSync(recursive: true));
      final want = _source(70000, 13);
      final path = '${dir.path}/a.bin';
      File(path).writeAsBytesSync(want);
      final input = InputFileStream(path);
      addTearDown(input.closeSync);
      final entry = ArchiveFile.stream('a.bin', input);
      for (var round = 0; round < 2; round++) {
        final held = _Held();
        ZipChunkedEncoder(held)
          ..add(entry, autoClose: false)
          ..close();
        expect(input.fileBuffer.isOpen, isTrue);
        final back = ZipDecoder().decodeBytes(held.bytes, verify: true);
        expect(back.files.single.content, want);
      }
    });

    test('large zstd, xz or bzip2 entry reads its file only once', testOn: 'vm',
        () async {
      final dir = Directory.systemTemp.createTempSync('zip_read_once');
      addTearDown(() => dir.deleteSync(recursive: true));
      final want = _source(3 << 20, 17);
      final path = '${dir.path}/a.bin';
      File(path).writeAsBytesSync(want);
      for (final type in [
        CompressionType.zstd,
        CompressionType.xz,
        CompressionType.bzip2,
      ]) {
        final handle = _ByteCountingHandle(path);
        final input = InputFileStream.withFileHandle(handle);
        addTearDown(input.closeSync);
        final bytes = await Stream.value(
                ArchiveFile.stream('a.bin', input)..compression = type)
            .transform(zipCodec.encoder)
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        expect(handle.bytes, lessThan(want.length * 3 ~/ 2), reason: type.name);
        final back = ZipDecoder()
            .decodeBytes(Uint8List.fromList(bytes), verify: true)
            .files
            .single;
        expect(back.content, want, reason: type.name);
      }
    });
  });

  group('zip with sizes in data descriptor (default)', () {
    for (final useAddLevel in [false, true]) {
      test('${useAddLevel ? 'add' : 'entry'} level override is respected', () {
        Uint8List payload(bool streamed) {
          final file = ArchiveFile.bytes('a', Uint8List(128 * 1024))
            ..compressionLevel = useAddLevel ? null : 0;
          final output = OutputMemoryStream();
          final encoder = ZipEncoder(streamed: streamed)
            ..startEncode(output, level: 1);
          encoder.add(file, level: useAddLevel ? 0 : null);
          encoder.endEncode();
          final archive = ZipDecoder().decodeBytes(output.getBytes());
          return (archive.files.single.rawContent! as ZipFile)
              .getStream(decompress: false)
              .toUint8List();
        }

        for (final streamed in [false, true]) {
          final stored = payload(streamed);
          expect(stored.length, greaterThan(128 * 1024),
              reason: 'streamed $streamed');
          expect(Inflate(stored).getBytes(), Uint8List(128 * 1024),
              reason: 'streamed $streamed');
        }
      });
    }

    // Deflate grows data that does not compress. 4293656835 bytes is the
    // largest entry whose worst case still fits 32 bits. One byte more is
    // written the way Info-ZIP writes a zip64 entry to a pipe
    test('entry that deflate may grow past 4 GB is written with zip64',
        testOn: 'vm', () {
      ByteData written(int size) {
        final output = OutputMemoryStream();
        ZipEncoder(streamed: true)
          ..startEncode(output)
          ..addHeader(ArchiveFile.file('a', size, FileContentMemory([1, 2, 3])))
              ?.finish();
        return ByteData.sublistView(output.getBytes());
      }

      final plain = written(4293656835);
      expect(plain.getUint16(4, Endian.little), 20);
      expect(plain.getUint32(18, Endian.little), 0);
      expect(plain.getUint16(28, Endian.little), 0);
      final plainEnd = plain.lengthInBytes;
      expect(plain.getUint32(plainEnd - 16, Endian.little), 0x08074b50);
      expect(plain.getUint32(plainEnd - 4, Endian.little), 3);

      final wide = written(4293656836);
      expect(wide.getUint16(4, Endian.little), 45);
      expect(wide.getUint32(18, Endian.little), 0xFFFFFFFF);
      expect(wide.getUint32(22, Endian.little), 0xFFFFFFFF);
      expect(wide.getUint16(28, Endian.little), 20);
      expect(wide.getUint16(31, Endian.little), 1);
      final wideEnd = wide.lengthInBytes;
      expect(wide.getUint32(wideEnd - 24, Endian.little), 0x08074b50);
      expect(wide.getUint64(wideEnd - 8, Endian.little), 3);
    });

    // An entry over 4 GB is streamed too, not held in memory
    test('entry over 4 GB is streamed with zip64', testOn: 'vm', () {
      final output = OutputMemoryStream();
      final encoder = ZipEncoder(streamed: true)..startEncode(output);
      final body = encoder.addHeader(
          ArchiveFile.file('a', 5000000000, FileContentMemory([1, 2, 3])));
      expect(body, isNotNull);
      body!.finish();
      encoder.endEncode();
      final view = ByteData.sublistView(output.getBytes());
      expect(view.getUint16(4, Endian.little), 45);
      expect(view.getUint32(22, Endian.little), 0xFFFFFFFF);
      expect(view.getUint16(28, Endian.little), 20);

      var central = 0;
      while (view.getUint32(central, Endian.little) != 0x02014b50) {
        central++;
      }
      expect(view.getUint32(central - 24, Endian.little), 0x08074b50);
      expect(view.getUint64(central - 8, Endian.little), 3);
      expect(view.getUint32(central + 24, Endian.little), 3);
    });

    test('encoder sends first bytes before compression reads whole entry', () {
      final bytes = _source(1024 * 1024, 17);
      final input = _ObservedInput(bytes);
      final output = _ObservedOutput(input);
      ZipChunkedEncoder(output)
        ..add(ArchiveFile.stream('a', input))
        ..close();
      expect(output.firstRead, isNotNull);
      // The CRC is computed during deflate, so no pass reads the source first
      expect(output.firstRead!, lessThan(2 * bytes.length));
    });

    test('streamed entry is read once', testOn: 'vm', () {
      final bytes = _source(1024 * 1024, 17);
      final input = _ObservedInput(bytes);
      final output = _Held();
      ZipChunkedEncoder(output)
        ..add(ArchiveFile.stream('a', input))
        ..close();
      expect(input.read, bytes.length);
      final back = ZipDecoder().decodeBytes(output.bytes, verify: true);
      expect(back.files.single.content, bytes);
    });

    test('entry without content decodes as empty file', () {
      final bytes = _zip([ArchiveFile.noData('empty')]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final file = archive.files.single.rawContent! as ZipFile;
      expect(
          file.compressionMethod != CompressionType.deflate ||
              file.compressedSize > 0,
          isTrue);
      expect(archive.files.single.content, isEmpty);
    });

    test('output decodes back', () {
      final want = _source(70000, 3);
      final back = ZipDecoder().decodeBytes(_zip(_entries()), verify: true);
      expect(back.files.map((f) => f.name), _entries().map((e) => e.name));
      expect(back.files[1].content, want);
    });

    test('central directory sets bit 3 like local header', () {
      // A reader that compares the two headers, 7-zip among them, calls the
      // pair broken when only one of them says the sizes follow the data
      final bytes = _zip([ArchiveFile.bytes('a.bin', _source(60000, 7))]);
      final eocd = bytes.length - 22;
      final centralAt = bytes[eocd + 16] |
          (bytes[eocd + 17] << 8) |
          (bytes[eocd + 18] << 16) |
          (bytes[eocd + 19] << 24);
      // signature, version made by, version needed, then the flag word
      expect(bytes[centralAt] | (bytes[centralAt + 1] << 8), 0x4b50);
      expect(bytes[centralAt + 8] & ZipEncoder.dataDescriptorBit,
          ZipEncoder.dataDescriptorBit);
      expect(
          bytes[6] & ZipEncoder.dataDescriptorBit, ZipEncoder.dataDescriptorBit,
          reason: 'the local header too');
    });

    test('local header has CRC and sizes set to 0 with bit 3', () {
      final bytes = _zip([ArchiveFile.bytes('a.bin', _source(60000, 7))]);
      // General purpose bit 3, then zeros where the check and sizes go
      expect(bytes[6] & ZipEncoder.dataDescriptorBit,
          ZipEncoder.dataDescriptorBit);
      for (var at = 14; at < 26; at++) {
        expect(bytes[at], 0, reason: 'byte $at');
      }
    });

    test('large entry is written in many pieces, not in one', testOn: 'vm',
        () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final path = '${directory.path}/big.bin';
        // Random enough that deflate cannot shrink it away
        File(path).writeAsBytesSync(_source(4 << 20, 19));
        final held = _Held();
        ZipChunkedEncoder(held)
          ..add(ArchiveFile.stream('big.bin', InputFileStream(path)))
          ..close();
        // Buffered, the whole entry would land in one piece
        expect(held.pieces, greaterThan(16));
        expect(
            ZipDecoder()
                .decodeBytes(held.bytes, verify: true)
                .files
                .single
                .size,
            4 << 20);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('zip codec', () {
    test('entries transform into archive equal to ZipEncoder output', () async {
      final bytes = await Stream.fromIterable(_entries())
          .transform(zipCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(bytes, _zip(_entries()));
      expect(ZipDecoder().decodeBytes(Uint8List.fromList(bytes)).files.length,
          _entries().length);
    });

    test('cancel of encoder over silent source releases source', () async {
      // Parked waiting for an entry that never comes, which a cancel used to
      // wait on for good
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(zipCodec.encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(_entries().first);
      await written.future.timeout(const Duration(seconds: 5));
      // Past the last piece of the entry, so it waits on the source
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel().timeout(const Duration(seconds: 5));
      expect(source.hasListener, isFalse);
      await source.close();
    });

    for (final streamed in [true, false]) {
      test(
          'streamed $streamed: source error ends archive stream with same '
          'error', () async {
        final source = StreamController<ArchiveFile>();
        final events = <String>[];
        final ended = Completer<void>();
        source.stream.transform(ZipCodec(streamed: streamed).encoder).listen(
            (_) => events.add('data'),
            onError: (Object error) => events.add('$error'),
            onDone: ended.complete);
        source.add(_entries().first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        source.addError(StateError('source failed'));
        await ended.future.timeout(const Duration(seconds: 5));
        expect(events.first, 'data');
        final failed = events.indexOf('Bad state: source failed');
        expect(events.sublist(failed), ['Bad state: source failed']);
        expect(source.hasListener, isFalse);
        await source.close();
      });
    }

    for (final autoClose in [false, true]) {
      test('autoClose $autoClose decides whether written entry is closed',
          () async {
        final content = _ClosingInput(_source(300000, 21));
        final bytes = await Stream.value(ArchiveFile.stream('big.bin', content))
            .transform(ZipCodec(autoClose: autoClose).encoder)
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        expect(bytes, isNotEmpty);
        expect(content.closed, autoClose);
      });
    }

    test('autoClose closes entry interrupted by cancel', () async {
      final content = _ClosingInput(_source(8 << 20, 23));
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(const ZipCodec(autoClose: true).encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(ArchiveFile.stream('big.bin', content));
      await written.future.timeout(const Duration(seconds: 10));
      await subscription.cancel().timeout(const Duration(seconds: 10));
      await source.close();
      expect(content.closed, isTrue);
    });

    for (final type in [
      CompressionType.none,
      CompressionType.zstd,
      CompressionType.xz,
      CompressionType.bzip2
    ]) {
      for (final streamed in [true, false]) {
        test(
            'cancel inside ${type.name} entry closes input, streamed $streamed',
            () async {
          final content = _ClosingInput(_source(3 << 20, 29));
          final source = StreamController<ArchiveFile>();
          final written = Completer<void>();
          var length = 0;
          final subscription = source.stream
              .transform(ZipCodec(streamed: streamed, autoClose: true).encoder)
              .listen((piece) {
            length += piece.length;
            if (length > 1 << 16 && !written.isCompleted) {
              written.complete();
            }
          });
          source
              .add(ArchiveFile.stream('big.bin', content)..compression = type);
          await written.future.timeout(const Duration(seconds: 20));
          await subscription.cancel().timeout(const Duration(seconds: 10));
          await source.close();
          expect(content.closed, isTrue);
        });
      }
    }

    for (final streamed in [true, false]) {
      test('streamed $streamed: entry is sent before next entry arrives',
          () async {
        final codec = ZipCodec(streamed: streamed);
        ArchiveFile entry() => ArchiveFile.string('a.txt', 'hello ' * 200)
          ..lastModTime = 1700000000;
        final alone = await Stream.value(entry())
            .transform(codec.encoder)
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        final at = alone.length - 6;
        final entrySize = alone[at] |
            (alone[at + 1] << 8) |
            (alone[at + 2] << 16) |
            (alone[at + 3] << 24);
        final source = StreamController<ArchiveFile>();
        var out = 0;
        final done = source.stream.transform(codec.encoder).forEach((piece) {
          out += piece.length;
        });
        source.add(entry());
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final beforeClose = out;
        await source.close();
        await done;
        expect(beforeClose, entrySize);
      });
    }

    test('entry bytes are unchanged after encode transformer', () async {
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'hello'));
      Future<List<int>> once() => Stream.fromIterable(archive.files)
          .transform(zipCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final first = await once();
      expect(archive.files.single.content, 'hello'.codeUnits);
      expect(await once(), first);
    });

    test('stream entry bytes are unchanged after encode transformer', () async {
      final want = _source(70000, 19);
      final entry = ArchiveFile.stream('a.bin', InputMemoryStream(want));
      await Stream.value(entry).transform(zipCodec.encoder).drain<void>();
      expect(entry.content, want);
    });

    for (final streamed in [true, false]) {
      test('streamed $streamed: level out of range throws ArgumentError',
          () async {
        expect(
            () => ZipEncoder(streamed: streamed).encodeBytes(
                Archive()..add(ArchiveFile.string('a.txt', 'hello')),
                level: 10),
            throwsA(isA<ArgumentError>()));
        await expectLater(
            Stream.value(ArchiveFile.string('a.txt', 'hello'))
                .transform(ZipCodec(level: 10, streamed: streamed).encoder)
                .drain<void>(),
            throwsA(isA<ArgumentError>()));
      });
    }

    for (final streamed in [false, true]) {
      test('stream entry stays readable after encodeBytes, streamed $streamed',
          () {
        final want = _source(70000, 23);
        final entry = ArchiveFile.stream('a.bin', InputMemoryStream(want));
        ZipEncoder(streamed: streamed).encodeBytes(Archive()..add(entry));
        expect(entry.content, want);
      });
    }
  });

  group('zip written to disk', () {
    // The stream writes an archive nothing reads back as it goes, so it is read
    // back afterwards the way a reader gets it: off disk, through the file
    // stream, and then extracted entry by entry
    test('stream output read from disk decodes back', testOn: 'vm', () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));

        final input = InputFileStream(path);
        final archive = ZipDecoder().decodeStream(input, verify: true);
        expect(archive.files.map((file) => file.name),
            _entries().map((entry) => entry.name));
        expect(archive.files[1].readBytes(), want);
        await input.close();
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('extractFileToDisk writes entries as files', testOn: 'vm', () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));

        await extractFileToDisk(path, '${directory.path}/out');
        expect(File('${directory.path}/out/dir/binary.dat').readAsBytesSync(),
            want);
        expect(File('${directory.path}/out/readme.txt').readAsStringSync(),
            'the first entry');
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('back pressure inside one entry', () {
    test('first bytes of large entry arrive before compression ends', () async {
      final content = _source(16 << 20, 11);
      final started = DateTime.now();
      var first = -1;
      await for (final piece in Stream<ArchiveFile>.fromIterable(
              [ArchiveFile.bytes('big.bin', content)])
          .transform(zipCodec.encoder)) {
        if (first < 0 && piece.isNotEmpty) {
          first = DateTime.now().difference(started).inMicroseconds;
        }
      }
      final whole = DateTime.now().difference(started).inMicroseconds;
      // The transform used to deflate the whole entry before its first yield,
      // which held every compressed byte of it in memory
      expect(first, lessThan(whole ~/ 4));
    });
  });

  group('streamed entry starting past 4 GB', () {
    test('only central record has zip64 field', testOn: 'vm', () {
      // The entry is small. Its offset is past 4 GB. The output already
      // reports a length of 4 GB before the first write
      final out = _OffsetOutput(0x100000000);
      final encoder = ZipEncoder(streamed: true);
      encoder.startEncode(out);
      encoder.add(ArchiveFile.string('small.txt', 'hello world'));
      encoder.endEncode();
      final bytes = out.bytes;
      final view = ByteData.sublistView(bytes);

      // Java takes the descriptor width from the real sizes. A small entry
      // gets a plain local header and 4 byte sizes behind its data
      expect(view.getUint16(4, Endian.little), 20);
      expect(view.getUint32(18, Endian.little), 0);
      expect(view.getUint16(28, Endian.little), 0);
      final at = _find(bytes, [0x50, 0x4b, 0x07, 0x08]);
      expect(at, greaterThan(0));
      expect(view.getUint32(at + 8, Endian.little), 13);
      expect(view.getUint32(at + 12, Endian.little), 11);

      final central = at + 16;
      expect(view.getUint32(central, Endian.little), 0x02014b50);
      expect(view.getUint16(central + 6, Endian.little), 45);
      expect(view.getUint32(central + 42, Endian.little), 0xFFFFFFFF);
      final nameLength = view.getUint16(central + 28, Endian.little);
      final zip64 = central + 46 + nameLength;
      expect(view.getUint16(zip64, Endian.little), 1);
      expect(view.getUint64(zip64 + 20, Endian.little), 0x100000000);
    });
  });

  group('entry whose length disagrees with isEOS', () {
    test('body ends instead of looping forever', () {
      final encoder = ZipEncoder(streamed: true);
      encoder.startEncode(OutputMemoryStream());
      final body =
          encoder.addHeader(ArchiveFile.stream('a.bin', _LyingInput(10)));
      expect(body, isNotNull);
      // zip_chunked and finish both run `while (step())`. A step that takes
      // nothing must return false. Otherwise both callers spin forever
      expect(body!.step(), isFalse);
      body.finish();
      encoder.endEncode();
    });
  });
}

/// Reports a length of 0 while it still holds bytes. A real InputStream can
/// behave this way
class _LyingInput extends InputMemoryStream {
  _LyingInput(int size) : super(Uint8List(size));

  @override
  int get length => 0;
}

int _find(Uint8List bytes, List<int> want) {
  for (var at = 0; at + want.length <= bytes.length; at++) {
    var same = true;
    for (var i = 0; i < want.length; i++) {
      if (bytes[at + i] != want[i]) {
        same = false;
        break;
      }
    }
    if (same) {
      return at;
    }
  }
  return -1;
}

/// Keeps everything written to it and adds [base] to its length. An entry
/// written here starts past 4 GB without a 4 GB buffer
class _OffsetOutput extends OutputStream {
  final int base;
  final _held = OutputMemoryStream();

  _OffsetOutput(this.base) : super(byteOrder: ByteOrder.littleEndian);

  Uint8List get bytes => _held.getBytes();

  @override
  int get length => base + _held.length;

  @override
  void clear() => _held.clear();

  @override
  void flush() => _held.flush();

  @override
  void writeByte(int value) => _held.writeByte(value);

  @override
  void writeBytes(List<int> bytes, {int? length}) =>
      _held.writeBytes(bytes, length: length);

  @override
  void writeStream(InputStream stream) => _held.writeStream(stream);

  @override
  Uint8List subset(int start, [int? end]) => _held.subset(start, end);

  @override
  Uint8List getBytes() => _held.getBytes();
}

class _ObservedInput extends InputMemoryStream {
  int read = 0;

  _ObservedInput(super.bytes);

  @override
  InputStream readBytes(int count) {
    final piece = super.readBytes(count);
    read += piece.length;
    return piece;
  }
}

class _ObservedOutput extends _Held {
  final _ObservedInput input;
  int? firstRead;

  _ObservedOutput(this.input);

  @override
  void add(List<int> data) {
    if (data.isNotEmpty) firstRead ??= input.read;
    super.add(data);
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

/// Counts the bytes read from the file
class _ByteCountingHandle extends AbstractFileHandle {
  final FileHandle _inner;
  int bytes = 0;

  _ByteCountingHandle(String path) : _inner = FileHandle(path);

  @override
  int get position => _inner.position;

  @override
  set position(int p) => _inner.position = p;

  @override
  int get length => _inner.length;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  bool open({FileAccess mode = FileAccess.read}) => _inner.open(mode: mode);

  @override
  Future<void> close() => _inner.close();

  @override
  void closeSync() => _inner.closeSync();

  @override
  int readInto(Uint8List buffer, [int? length]) {
    final got = _inner.readInto(buffer, length);
    bytes += got;
    return got;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      _inner.writeFromSync(buffer, start, end);
}

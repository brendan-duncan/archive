@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

class _MeteredInputStream extends InputMemoryStream {
  _MeteredInputStream(Uint8List bytes) : super(bytes);

  int scannedBytes = 0;

  @override
  InputStream readBytes(int count) {
    scannedBytes += count;
    return super.readBytes(count);
  }
}

void main() {
  test('EOCD at EOF does not scan the archive payload', () {
    final content = Uint8List(2 * 1024 * 1024);
    final archive = Archive()
      ..addFile(ArchiveFile.noCompress('file.bin', content.length, content));
    final input = _MeteredInputStream(ZipEncoder().encodeBytes(archive));
    final directory = ZipDirectory()..read(input);
    expect(directory.fileHeaders.single.filename, 'file.bin');
    expect(directory.filePosition, input.totalLength - ZipDirectory.eocdSize);
    expect(input.scannedBytes, lessThan(2048));
  });

  test('a trailing-junk fallback does not scan the archive payload', () {
    final content = Uint8List(2 * 1024 * 1024);
    final archive = Archive()
      ..addFile(ArchiveFile.noCompress('file.bin', content.length, content));
    final bytes = ZipEncoder().encodeBytes(archive);
    final input = _MeteredInputStream(
        Uint8List.fromList([...bytes, ...List.filled(70000, 0x2e)]));
    final directory = ZipDirectory()..read(input);
    expect(directory.fileHeaders.single.filename, 'file.bin');
    expect(directory.filePosition, bytes.length - ZipDirectory.eocdSize);
    expect(input.scannedBytes, lessThan(72 * 1024));
  });

  test('EOCD signatures straddling reverse chunks remain readable', () {
    for (final length in [1019, 1020, 1021, 1022, 1023]) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('file.txt', 'data'))
        ..comment = ''.padRight(length, 'x');
      final bytes = ZipEncoder().encodeBytes(archive);
      expect(ZipDecoder().decodeBytes(bytes, verify: true).single.readBytes(),
          'data'.codeUnits,
          reason: 'comment=$length');
    }
  });

  test('EOCD-looking bytes inside a ZIP comment are not preferred', () {
    final original = Archive()
      ..addFile(ArchiveFile.string('payload.txt', 'valid content'))
      ..comment = 'prefix-PK\u0005\u0006-' + ''.padRight(100, 'x');
    final bytes = ZipEncoder().encodeBytes(original);

    final input = InputMemoryStream(bytes);
    final decoder = ZipDecoder();
    final decoded = decoder.decodeStream(input, verify: true);
    expect(decoded.length, 1);
    expect(decoded.single.name, 'payload.txt');
    expect(decoded.single.readBytes(), 'valid content'.codeUnits);
    expect(
      decoder.directory.filePosition,
      bytes.length - ZipDirectory.eocdSize - original.comment!.length,
    );
  });

  test('ZIP with trailing junk keeps the compatibility fallback', () {
    final archive = Archive()..addFile(ArchiveFile.string('file.txt', 'data'));
    final bytes = ZipEncoder().encodeBytes(archive);
    final trailing = Uint8List.fromList([...bytes, ...List.filled(14, 0x2e)]);
    expect(
      ZipDecoder().decodeBytes(trailing).single.readBytes(),
      'data'.codeUnits,
    );
  });

  test('a maximal 65535-byte ZIP comment remains readable', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('file.txt', 'data'))
      ..comment = ''.padRight(65535, 'x');
    final decoded = ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(archive));
    expect(decoded.single.readBytes(), 'data'.codeUnits);
  });

  test('maximal comment plus short trailing junk still decodes', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('file.txt', 'data'))
      ..comment = ''.padRight(65535, 'x');
    final bytes = ZipEncoder().encodeBytes(archive);
    final trailing = Uint8List.fromList([...bytes, ...List.filled(512, 0x2e)]);
    expect(
      ZipDecoder().decodeBytes(trailing).single.readBytes(),
      'data'.codeUnits,
    );
  });

  for (final (commentLength, trailingLength) in [(0, 70000), (65535, 4097)]) {
    test('long trailing bytes decode ($commentLength, $trailingLength)', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('file.txt', 'data'))
        ..comment = ''.padRight(commentLength, 'x');
      final bytes = ZipEncoder().encodeBytes(archive);
      final input = InputMemoryStream(
        Uint8List.fromList([...bytes, ...List.filled(trailingLength, 0x2e)]),
      )..setPosition(7);
      final decoded = ZipDecoder().decodeStream(input, verify: true);
      expect(input.position, 7);
      expect(decoded.single.readBytes(), 'data'.codeUnits);
    });
  }

  test('long trailing bytes work with ZIP64 and a prefix', () {
    final bytes = File('test/_data/zip/zip64_archive.zip').readAsBytesSync();
    final expected = ZipDecoder().decodeBytes(bytes, verify: true);
    final padded = Uint8List.fromList([
      ...List.filled(37, 0x4d),
      ...bytes,
      ...List.filled(70000, 0x2e),
    ]);
    final actual = ZipDecoder().decodeBytes(padded, verify: true);
    expect(actual.map((file) => file.name), expected.map((file) => file.name));
    for (var i = 0; i < actual.length; i++) {
      expect(actual[i].readBytes(), expected[i].readBytes());
    }
  });

  test('file extraction reads a ZIP with long trailing bytes', () async {
    final dir = Directory.systemTemp.createTempSync('archive-eocd-extract-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final archive = Archive()..addFile(ArchiveFile.string('file.txt', 'data'));
    final file = File('${dir.path}/archive.zip')
      ..writeAsBytesSync([
        ...ZipEncoder().encodeBytes(archive),
        ...List.filled(70000, 0x2e),
      ]);
    await extractFileToDisk(file.path, '${dir.path}/out');
    expect(File('${dir.path}/out/file.txt').readAsStringSync(), 'data');
  });

  test('trailing bytes remain readable past the former search window', () {
    const window = 0xffff + 4096;
    for (final comment in [0, 1000]) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('file.txt', 'data'))
        ..comment = ''.padRight(comment, 'x');
      final bytes = ZipEncoder().encodeBytes(archive);
      Uint8List withJunk(int junk) =>
          Uint8List.fromList([...bytes, ...List.filled(junk, 0x2e)]);
      expect(
        ZipDecoder().decodeBytes(withJunk(window - comment)).length,
        1,
        reason: 'comment=$comment',
      );
      expect(
        ZipDecoder().decodeBytes(withJunk(window - comment + 1)).length,
        1,
        reason: 'comment=$comment',
      );
    }
  });

  test('a malformed file preserves the stream position', () {
    final dir = Directory.systemTemp.createTempSync('archive-eocd-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/invalid.zip')
      ..writeAsBytesSync(Uint8List(8 * 1024 * 1024));
    final handle = _ByteCountingHandle(file.path);
    final input = InputFileStream.withFileHandle(handle)..setPosition(123);
    try {
      expect(ZipDecoder().decodeStream(input), isEmpty);
      expect(input.position, 123);
    } finally {
      input.closeSync();
    }
  });

  test('a record straddling two chunks past the window is found', () {
    // Past the comment window the chunk doubles from 1 KB to 64 KB. These
    // lengths of trailing bytes put the record on each boundary up to the
    // first between two 64 KB chunks, where a search without the three byte
    // overlap misses it
    final archive = Archive()..addFile(ArchiveFile.string('file.txt', 'data'));
    final zip = ZipEncoder().encodeBytes(archive);
    const ranges = [
      (66000, 81500),
      (96500, 98000),
      (129500, 130500),
      (195000, 196000)
    ];
    final padded = Uint8List(zip.length + ranges.last.$2)
      ..fillRange(zip.length, zip.length + ranges.last.$2, 0x2e)
      ..setRange(0, zip.length, zip);
    final missed = <int>[];
    for (final (from, to) in ranges) {
      for (var junk = from; junk <= to; junk++) {
        final directory = ZipDirectory()
          ..read(InputMemoryStream(
              Uint8List.sublistView(padded, 0, zip.length + junk)));
        if (directory.filePosition != zip.length - ZipDirectory.eocdSize ||
            directory.fileHeaders.length != 1) {
          missed.add(junk);
        }
      }
    }
    expect(missed, isEmpty);
  });
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

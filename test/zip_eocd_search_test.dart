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
  test('EOCD lookup inspects only the ZIP comment window', () {
    // No EOCD: a linear scan of all 2 MiB wastes file I/O on corrupt ZIPs.
    final input = _MeteredInputStream(Uint8List(2 * 1024 * 1024));
    final decoder = ZipDecoder();
    final decoded = decoder.decodeStream(input);
    expect(decoded, isEmpty);
    expect(decoder.directory.filePosition, -1);
    expect(input.scannedBytes, lessThan(100 * 1024));
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
    expect(decoder.directory.filePosition,
        bytes.length - ZipDirectory.eocdSize - original.comment!.length);
  });

  test('ZIP with trailing junk keeps the compatibility fallback', () {
    final archive = Archive()..addFile(ArchiveFile.string('file.txt', 'data'));
    final bytes = ZipEncoder().encodeBytes(archive);
    final trailing = Uint8List.fromList([...bytes, ...List.filled(14, 0x2e)]);
    expect(ZipDecoder().decodeBytes(trailing).single.readBytes(),
        'data'.codeUnits);
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
    expect(ZipDecoder().decodeBytes(trailing).single.readBytes(),
        'data'.codeUnits);
  });

  test('trailing bytes are accepted up to the end of the search window', () {
    // The record is searched for in the last 65535 + 4096 + 22 bytes, which
    // the comment and any bytes after the archive share
    const window = 0xffff + 4096;
    for (final comment in [0, 1000]) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('file.txt', 'data'))
        ..comment = ''.padRight(comment, 'x');
      final bytes = ZipEncoder().encodeBytes(archive);
      Uint8List withJunk(int junk) =>
          Uint8List.fromList([...bytes, ...List.filled(junk, 0x2e)]);
      expect(ZipDecoder().decodeBytes(withJunk(window - comment)).length, 1,
          reason: 'comment=$comment');
      expect(ZipDecoder().decodeBytes(withJunk(window - comment + 1)), isEmpty,
          reason: 'comment=$comment');
    }
  });

  test('a large malformed file on disk does not require a full scan', () {
    final dir = Directory.systemTemp.createTempSync('archive-eocd-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/invalid.zip')
      ..writeAsBytesSync(Uint8List(8 * 1024 * 1024));
    final handle = _ByteCountingHandle(file.path);
    final input = InputFileStream.withFileHandle(handle);
    try {
      expect(ZipDecoder().decodeStream(input), isEmpty);
    } finally {
      input.closeSync();
    }
    // The whole file is 8 MB; the search window is under 70 KB
    expect(handle.bytes, lessThan(512 * 1024));
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

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
    final archive = Archive()
      ..addFile(ArchiveFile.string('file.txt', 'data'));
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
    final trailing =
        Uint8List.fromList([...bytes, ...List.filled(512, 0x2e)]);
    expect(ZipDecoder().decodeBytes(trailing).single.readBytes(),
        'data'.codeUnits);
  });

  test('a large malformed file on disk does not require a full scan', () {
    final dir = Directory.systemTemp.createTempSync('archive-eocd-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/invalid.zip')
      ..writeAsBytesSync(Uint8List(2 * 1024 * 1024));
    final input = InputFileStream(file.path);
    try {
      expect(ZipDecoder().decodeStream(input), isEmpty);
    } finally {
      input.closeSync();
    }
  });
}

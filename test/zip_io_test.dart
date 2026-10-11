@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:archive/src/codecs/zip/zip_file.dart' show zipDecodeBufferSize;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// 64-bit literals do not compile under dart2js, so these stay out of
// zip_test.dart, which also runs on the web
void main() {
  test('a zip entry presizes only what its data could decode to', () {
    // A zip64 size over 2^63 reads as negative
    expect(zipDecodeBufferSize(-1, 600 << 20), isNull);
    expect(zipDecodeBufferSize(0, 600 << 20), isNull);
    expect(zipDecodeBufferSize(1 << 40, 100), 100 * 1032);
    expect(zipDecodeBufferSize(1 << 40, 600 << 20), 500 << 20);
    expect(zipDecodeBufferSize(700 << 20, 600 << 20), 500 << 20);
    expect(zipDecodeBufferSize(1000, 600 << 20), 1000);
  });

  group('crafted zip64 sizes do not crash', () {
    // A zip64 extra field can declare a 64-bit compressed size. When it is
    // near the 64-bit maximum, the old bounds checks overflowed and either
    // built an out-of-range Uint8List over the tiny file (an uncatchable
    // crash on builds without a range check) or over-allocated. Reading an
    // entry must instead return at most the bytes actually present.
    Uint8List craft(int compressedSize) {
      final name = ascii.encode('a');
      final data = ascii.encode('x');
      final local = BytesBuilder();
      final lh = OutputMemoryStream()
        ..writeUint32(0x04034b50)
        ..writeUint16(20)
        ..writeUint16(0)
        ..writeUint16(0) // stored
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint32(0)
        ..writeUint32(data.length)
        ..writeUint32(1)
        ..writeUint16(name.length)
        ..writeUint16(0);
      local.add(lh.getBytes());
      local.add(name);
      local.add(data);
      final localBytes = local.takeBytes();

      final extra = OutputMemoryStream()
        ..writeUint16(1) // zip64 tag
        ..writeUint16(8)
        ..writeUint64(compressedSize);
      final extraBytes = extra.getBytes();

      final cd = OutputMemoryStream()
        ..writeUint32(0x02014b50)
        ..writeUint16(20)
        ..writeUint16(20)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint32(0)
        ..writeUint32(0xffffffff) // compressed size -> use zip64 extra
        ..writeUint32(1)
        ..writeUint16(name.length)
        ..writeUint16(extraBytes.length)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint32(0)
        ..writeUint32(0); // local header offset
      cd.writeBytes(name);
      cd.writeBytes(extraBytes);
      final cdBytes = cd.getBytes();

      final eocd = OutputMemoryStream()
        ..writeUint32(0x06054b50)
        ..writeUint16(0)
        ..writeUint16(0)
        ..writeUint16(1)
        ..writeUint16(1)
        ..writeUint32(cdBytes.length)
        ..writeUint32(localBytes.length)
        ..writeUint16(0);

      final out = BytesBuilder()
        ..add(localBytes)
        ..add(cdBytes)
        ..add(eocd.getBytes());
      return out.takeBytes();
    }

    for (final size in <int>[
      0x00000000ffffffff,
      0x0000800000000000,
      0x7fffffffffffffff,
      0x8000000000000000, // -2^63
      0xffffffffffffffff, // -1 as a signed 64-bit int
    ]) {
      test('0x${size.toRadixString(16)}', () {
        final bytes = craft(size);

        void check(Archive archive) {
          expect(archive.length, 1);
          final entry = archive.first;
          // No throw, and never more than the bytes in the file.
          final content = entry.readBytes();
          expect(content, isNotNull);
          expect(content!.length, lessThanOrEqualTo(bytes.length));
          // Reading every byte must stay in bounds.
          var sum = 0;
          for (final b in content) {
            sum += b;
          }
          expect(sum, greaterThanOrEqualTo(0));
        }

        // In-memory path.
        check(ZipDecoder().decodeBytes(bytes));

        // File-backed path.
        final dir = Directory.systemTemp.createTempSync('archive-zip64-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = p.join(dir.path, 'evil.zip');
        File(path).writeAsBytesSync(bytes);
        final input = InputFileStream(path);
        check(ZipDecoder().decodeStream(input));
        input.closeSync();
      });
    }
  });
}

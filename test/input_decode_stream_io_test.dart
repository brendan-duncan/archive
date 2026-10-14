@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:archive/src/util/chunked_sink.dart';
import 'package:test/test.dart';

import '_test_util.dart';
import 'chunked_sink_decoder_test.dart' show drain;
import 'input_decode_stream_test.dart' show readAll;

class _WatchedDecoder extends ChunkDecoder {
  final String path;
  var _left = 200;
  int? onDiskAtEnd;

  _WatchedDecoder(this.path);

  @override
  bool decodeChunk(OutputStream output) {
    if (_left == 0) {
      return false;
    }
    if (--_left == 0) {
      onDiskAtEnd = File(path).lengthSync();
    }
    output.writeBytes(Uint8List(4096)..fillRange(0, 4096, _left & 0xff));
    return _left > 0;
  }
}

void main() {
  test('OutputFileStream.writeStream writes a lazy stream as it decodes', () {
    final path = '$testOutputPath/lazy_write.bin';
    final decoder = _WatchedDecoder(path);
    final output = OutputFileStream(path, bufferSize: 64 * 1024);
    output.writeStream(InputDecodeStream(decoder));
    output.closeSync();
    expect(File(path).lengthSync(), 200 * 4096);
    expect(decoder.onDiskAtEnd, greaterThan(100 * 4096));
  });

  test('ProgressOutputStream.writeStream writes a lazy stream as it decodes',
      () {
    final path = '$testOutputPath/lazy_progress_write.bin';
    final decoder = _WatchedDecoder(path);
    final output = ProgressOutputStream(
        OutputFileStream(path, bufferSize: 64 * 1024), (_) {});
    output.writeStream(InputDecodeStream(decoder));
    output.closeSync();
    expect(File(path).lengthSync(), 200 * 4096);
    expect(decoder.onDiskAtEnd, greaterThan(100 * 4096));
  });

  // XZEncoder writes uncompressed LZMA2 chunks, so the archive comes from
  // `head -c 16777216 /dev/zero | xz -0 -T1 -c`: one block, many chunks
  test('xz decodes at most one LZMA2 chunk per chunk', () {
    final xz = File('test/_data/xz/zeros-16m.xz').readAsBytesSync();
    final result = drain(ChunkedSinkDecoder(
        InputMemoryStream(xz), (output) => XzChunkedDecoder(output)));
    expect(result.total, 16 << 20);
    expect(result.largest, lessThanOrEqualTo(2 << 20));
  });

  group('decodeLazy', () {
    test('xz', () {
      // Real archives: checks summed on the way, concatenated streams, and
      // the x86 filter, which has to see the whole block.
      for (final name in ['crc32', 'crc64', 'sha256', 'concatenated', 'x86']) {
        final bytes = File('test/_data/xz/$name.xz').readAsBytesSync();
        final expected = XZDecoder().decodeBytes(bytes, verify: true);
        final lazy =
            XZDecoder().decodeLazy(InputMemoryStream(bytes), verify: true);
        compareBytes(readAll(lazy, 777), expected);
      }
      // A damaged check is caught when the block ends.
      final bytes = File('test/_data/xz/crc32.xz').readAsBytesSync();
      final index = bytes.length - 12 - 4 - 8;
      bytes[index] ^= 0xff;
      final lazy =
          XZDecoder().decodeLazy(InputMemoryStream(bytes), verify: true);
      expect(() => readAll(lazy), throwsA(isA<ArchiveException>()));
    });
  });
}

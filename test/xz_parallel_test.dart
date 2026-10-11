@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/bcj_x86.dart';
import 'package:archive/src/codecs/xz/_xz_parallel_io.dart'
    show xzDecodeJob, xzDecodeMultithreaded, xzKindBlock;
import 'package:archive/src/codecs/xz/xz_index.dart';
import 'package:archive/src/codecs/xz/xz_stream_decoder.dart'
    show xzStagingSize;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The reference tool made these archives, not this package, so we keep them as
// fixtures. A test suite runs where no xz binary does. Each one is
// `sampleData(1200000)` through `xz -z -c` with these options. `huge` is 48
// blocks of 64 MiB of zeros through `xz -0 -T4 --block-size=64MiB`:
//   blocks       --block-size=65536 --lzma2=preset=1
//   whole        --lzma2=preset=1
//   crc64        --check=crc64 --lzma2=preset=1
//   crc32        --block-size=65536 --check=crc32 --lzma2=preset=1
//   crc64-blocks --block-size=65536 --check=crc64 --lzma2=preset=1
//   sha256       --block-size=65536 --check=sha256 --lzma2=preset=1
//   x86          --block-size=65536 --x86 --lzma2=preset=1
//   x86-whole    --x86 --lzma2=preset=1
Uint8List fixture(String name) =>
    File('test/_data/xz/parallel/$name.xz').readAsBytesSync();

/// Where one block sits in an archive, read from the index the archive carries
class BlockInfo {
  final int compOffset;
  final int uncompOffset;
  final int totalSize;
  final int uncompSize;
  final int headerSize;

  BlockInfo(this.compOffset, this.uncompOffset, this.totalSize, this.uncompSize,
      this.headerSize);

  /// Offset of the first byte of compressed data, past the block header.
  int get dataOffset => compOffset + headerSize;

  /// Offset of the check field, which is the tail of the block.
  int checkOffset(int checkSize) => compOffset + totalSize - checkSize;
}

/// The blocks of [bytes], so that a test can damage one block on purpose
/// rather than a byte somewhere in the middle
List<BlockInfo> blocksOf(Uint8List bytes) {
  final layout = parseXZLayout(XZMemorySource(bytes))!;
  return [
    for (final block in layout.blocks)
      BlockInfo(
        block.compressedOffset,
        block.outputOffset,
        block.compressedLength,
        block.uncompressedLength,
        (bytes[block.compressedOffset] + 1) * 4,
      ),
  ];
}

/// A fixture and where its blocks are
({Uint8List bytes, List<BlockInfo> blocks}) buildArchive(String name) {
  final bytes = fixture(name);
  return (bytes: bytes, blocks: blocksOf(bytes));
}

/// Something that compresses well enough to be worth several blocks, with
/// enough variety that a block boundary landing in the wrong place shows up.
Uint8List sampleData(int length) {
  final data = Uint8List(length);
  var state = 0x2545f491;
  for (var i = 0; i < length; i++) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    // Mostly a repeating pattern, with occasional noise.
    data[i] = (i % 251) ^ ((state & 0xff) < 16 ? state & 0xff : 0);
  }
  return data;
}

List<int> _uint32(int value) =>
    [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, value >>> 24];

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  return out..add(value);
}

/// Returns [xz] with every index record set to [claim] uncompressed bytes and
/// the index CRC and footer recomputed
Uint8List withIndexClaim(Uint8List xz, int claim) {
  final backward =
      ByteData.sublistView(xz).getUint32(xz.length - 8, Endian.little);
  final indexAt = xz.length - 12 - (backward + 1) * 4;
  var at = indexAt + 1;
  int read() {
    var value = 0;
    for (var shift = 0;; shift += 7) {
      final byte = xz[at++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) {
        return value;
      }
    }
  }

  final count = read();
  final records = [0x00, ..._varint(count)];
  for (var i = 0; i < count; i++) {
    final unpadded = read();
    read();
    records
      ..addAll(_varint(unpadded))
      ..addAll(_varint(claim));
  }
  while (records.length % 4 != 0) {
    records.add(0);
  }
  final index = [...records, ..._uint32(getCrc32(records))];
  final flags = xz.sublist(xz.length - 4, xz.length - 2);
  final footer = [..._uint32(index.length ~/ 4 - 1), ...flags];
  return Uint8List.fromList([
    ...xz.sublist(0, indexAt),
    ...index,
    ..._uint32(getCrc32(footer)),
    ...footer,
    0x59,
    0x5a,
  ]);
}

Uint8List emptyBlockStream() {
  const flags = [0x00, 0x01];
  final blockHeader = [0x02, 0xc0, 0x01, 0x00, 0x21, 0x01, 0x00, 0x00];
  final block = [
    ...blockHeader,
    ..._uint32(getCrc32(blockHeader)),
    0x00,
    0x00,
    0x00,
    0x00,
    ..._uint32(0),
  ];
  final records = [0x00, 0x01, blockHeader.length + 4 + 1 + 4, 0x00];
  final index = [...records, ..._uint32(getCrc32(records))];
  final backward = [..._uint32(index.length ~/ 4 - 1), ...flags];
  return Uint8List.fromList([
    0xfd,
    0x37,
    0x7a,
    0x58,
    0x5a,
    0x00,
    ...flags,
    ..._uint32(getCrc32(flags)),
    ...block,
    ...index,
    ..._uint32(getCrc32(backward)),
    ...backward,
    0x59,
    0x5a,
  ]);
}

Future<Uint8List> decodeBytesOnIsolates(Uint8List compressed,
    {bool verify = false, int? workers, int? memoryBudget}) {
  final completer = Completer<Uint8List>();
  final returned = XZDecoder().decodeBytes(compressed,
      verify: verify,
      multithread: XZMultithreadOptions(
        onDone: completer.complete,
        onError: completer.completeError,
        workers: workers,
        memoryBudget: memoryBudget,
      ));
  // Documented: in multithreaded mode the return value carries nothing.
  expect(returned, isEmpty);
  return completer.future;
}

Future<bool> decodeStreamOnIsolates(InputStream input, OutputStream output,
    {bool verify = false, int? workers, int? memoryBudget}) {
  final completer = Completer<bool>();
  final returned = XZDecoder().decodeStream(input, output,
      verify: verify,
      multithread: XZMultithreadOptions(
        onDone: completer.complete,
        onError: completer.completeError,
        workers: workers,
        memoryBudget: memoryBudget,
      ));
  expect(returned, isFalse);
  return completer.future;
}

void main() {
  group('xz multithreaded', () {
    final expected = sampleData(1200000);

    test('multi block archive matches the single threaded decode', () async {
      final compressed = fixture('blocks');
      // A single block would make the whole exercise pointless.
      expect(XZDecoder().uncompressedSize(compressed), expected.length);

      final sequential = XZDecoder().decodeBytes(compressed);
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);

      expect(sequential, equals(expected));
      expect(parallel, equals(expected));
    });

    test('index claim does not size the result buffer', () async {
      final data = Uint8List(1000);
      final forged = withIndexClaim(XZEncoder().encodeBytes(data), 1500 << 20);
      expect(XZDecoder().uncompressedSize(forged), 1500 << 20);
      final ceiling = forged.length * 8192;

      final single = XZDecoder().decodeBytes(forged);
      expect(single, equals(data));
      expect(single.buffer.lengthInBytes, lessThanOrEqualTo(ceiling));

      final parallel = await decodeBytesOnIsolates(forged, workers: 2);
      expect(parallel, equals(data));
      expect(parallel.buffer.lengthInBytes, lessThanOrEqualTo(ceiling));
    });

    test('maxOutputSize bounds a decode on workers', () async {
      final compressed = fixture('blocks');
      for (final workers in [1, 4]) {
        for (final max in [expected.length, expected.length - 1]) {
          final over = max < expected.length;
          final bytes = Completer<Uint8List>();
          XZDecoder().decodeBytes(compressed,
              maxOutputSize: max,
              multithread: XZMultithreadOptions(
                  onDone: bytes.complete,
                  onError: bytes.completeError,
                  workers: workers));
          if (over) {
            await expectLater(bytes.future, throwsA(isA<ArchiveException>()),
                reason: 'decodeBytes, $workers workers');
          } else {
            expect(await bytes.future, equals(expected));
          }

          final output = OutputMemoryStream();
          final stream = Completer<bool>();
          XZDecoder().decodeStream(InputMemoryStream(compressed), output,
              maxOutputSize: max,
              multithread: XZMultithreadOptions(
                  onDone: stream.complete,
                  onError: stream.completeError,
                  workers: workers));
          if (over) {
            await expectLater(stream.future, throwsA(isA<ArchiveException>()),
                reason: 'decodeStream, $workers workers');
            expect(output.length, lessThanOrEqualTo(max));
          } else {
            expect(await stream.future, isTrue);
            expect(output.getBytes(), equals(expected));
          }
        }
      }
    });

    test('blocks run at most two per worker ahead of a slow first block',
        () async {
      final random = Random(1);
      final parts = <int>[
        ...XZEncoder().encodeBytes(Uint8List.fromList(
            List.generate(8 << 20, (_) => random.nextInt(16)))),
      ];
      for (var i = 0; i < 40; i++) {
        parts.addAll(XZEncoder().encodeBytes(Uint8List(65536)));
      }
      final bytes = Uint8List.fromList(parts);
      final layout = parseXZLayout(XZMemorySource(bytes))!;
      var firstDone = false;
      final ahead = <int>{};
      final ok = await xzDecodeMultithreaded(
        bytes: bytes,
        layout: layout,
        verify: false,
        maxPreallocateSize: 1 << 30,
        workers: 4,
        orderedOutput: true,
        fileReadBufferSize: 1 << 20,
        onChunk: (offset, chunk) {},
        onBlockDone: (block, ok) {
          if (block == 0) {
            firstDone = true;
          } else if (!firstDone) {
            ahead.add(block);
          }
        },
      );
      expect(ok, isTrue);
      expect(ahead.length, lessThanOrEqualTo(2 * 4));
    });

    group('an index that misstates a block', () {
      // Rewrites the size the index gives the first 64 KB block, keeping the
      // index CRC valid. Each block is placed by the index, so the decoded
      // blocks no longer meet: before blocks were checked against it, the
      // ordered writer held everything after the first block in memory and
      // the decode reported success with the output cut short.
      Uint8List misstate(Uint8List compressed, List<int> size) {
        final bytes = Uint8List.fromList(compressed);
        final footer = bytes.length - 12;
        final backwardSize = ByteData.sublistView(bytes, footer + 4, footer + 8)
            .getUint32(0, Endian.little);
        final indexStart = footer - (backwardSize + 1) * 4;
        // Indicator and a one byte record count, then the first record's
        // unpadded size, which is under 16 KB here so two bytes.
        final at = indexStart + 2 + 2;
        expect(bytes.sublist(at, at + 3), equals([0x80, 0x80, 0x04]));
        bytes.setRange(at, at + 3, size);
        final crcAt = footer - 4;
        ByteData.sublistView(bytes, crcAt, crcAt + 4).setUint32(
            0, getCrc32(bytes.sublist(indexStart, crcAt)), Endian.little);
        return bytes;
      }

      for (final (name, size) in [
        ('too small', [0xff, 0xff, 0x03]),
        ('too large', [0x81, 0x80, 0x04]),
      ]) {
        test('$name is refused by decodeStream', () async {
          final compressed = misstate(fixture('blocks'), size);
          final output = OutputMemoryStream();
          final ok = await decodeStreamOnIsolates(
              InputMemoryStream(compressed), output,
              workers: 4);
          expect(ok, isFalse);
          expect(output.length, lessThanOrEqualTo(65536));
        });

        test('$name is refused by decodeBytes', () async {
          final compressed = misstate(fixture('blocks'), size);
          final completer = Completer<Uint8List>();
          XZDecoder().decodeBytes(compressed,
              throwOnError: true,
              multithread: XZMultithreadOptions(
                  workers: 4,
                  onDone: completer.complete,
                  onError: completer.completeError));
          await expectLater(completer.future, throwsA(isA<ArchiveException>()));
        });
      }
    });

    test('maxDictionarySize refuses blocks on workers', () async {
      final compressed = fixture('blocks');
      for (final workers in [1, 4]) {
        final bytes = Completer<Uint8List>();
        XZDecoder(maxDictionarySize: 0).decodeBytes(compressed,
            throwOnError: true,
            multithread: XZMultithreadOptions(
                onDone: bytes.complete,
                onError: bytes.completeError,
                workers: workers));
        await expectLater(bytes.future, throwsA(isA<ArchiveException>()),
            reason: 'decodeBytes, $workers workers');

        final stream = Completer<bool>();
        XZDecoder(maxDictionarySize: 0).decodeStream(
            InputMemoryStream(compressed), OutputMemoryStream(),
            multithread: XZMultithreadOptions(
                onDone: stream.complete,
                onError: stream.completeError,
                workers: workers));
        expect(await stream.future, isFalse,
            reason: 'decodeStream, $workers workers');
      }
    });

    test('applies the BCJ x86 filter across blocks', () async {
      final compressed = fixture('x86');
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);
      expect(parallel, equals(expected));
      expect(XZDecoder().decodeBytes(compressed), equals(expected));
    });

    test('BCJ x86 filter applied in pieces equals whole-buffer result', () {
      final random = Random(7);
      for (var round = 0; round < 2000; round++) {
        final data = Uint8List(random.nextInt(3000));
        for (var i = 0; i < data.length; i++) {
          final kind = random.nextInt(8);
          data[i] = kind < 2
              ? 0xe8 + random.nextInt(2)
              : kind < 5
                  ? (random.nextBool() ? 0 : 0xff)
                  : random.nextInt(256);
        }
        final startOffset = round.isEven ? 0 : random.nextInt(1 << 20);
        final whole = Uint8List.fromList(data);
        bcjX86Decode(whole, startOffset);

        final output = OutputMemoryStream();
        final filter = BcjX86OutputStream(output, startOffset);
        var at = 0;
        while (at < data.length) {
          final end = min(data.length, at + 1 + random.nextInt(300));
          filter.writeRange(data, at, end);
          at = end;
        }
        filter.finish();
        expect(output.getBytes(), equals(whole), reason: 'round $round');
      }
    });

    test('x86 block decodes through converter in pieces', () async {
      final compressed = fixture('x86-whole');
      var largest = 0;
      final out = BytesBuilder(copy: false);
      await for (final piece in Stream<List<int>>.fromIterable([
        for (var at = 0; at < compressed.length; at += 1 << 16)
          compressed.sublist(at, min(compressed.length, at + (1 << 16)))
      ]).transform(xzCodec.decoder)) {
        largest = max(largest, piece.length);
        out.add(piece);
      }
      expect(out.toBytes(), equals(expected));
      expect(largest, lessThanOrEqualTo(1 << 16));
    });

    test('x86 block decodes into file output', () async {
      final dir = Directory.systemTemp.createTempSync('archive_xz_x86');
      try {
        final path = p.join(dir.path, 'out.bin');
        final output = OutputFileStream(path);
        final ok = XZDecoder()
            .decodeStream(InputMemoryStream(fixture('x86-whole')), output);
        await output.close();
        expect(ok, isTrue);
        expect(File(path).readAsBytesSync(), equals(expected));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('decodeStream into file output verifies every check type', () async {
      final dir = Directory.systemTemp.createTempSync('archive_xz_check');
      try {
        final path = p.join(dir.path, 'out.bin');
        for (final (name, size, reason) in [
          ('crc32', 4, 'CRC32'),
          ('crc64-blocks', 8, 'CRC64'),
          ('sha256', 32, 'SHA-256'),
        ]) {
          final built = buildArchive(name);
          var output = OutputFileStream(path);
          expect(
              XZDecoder().decodeStream(InputMemoryStream(built.bytes), output,
                  verify: true),
              isTrue,
              reason: name);
          await output.close();
          expect(File(path).readAsBytesSync(), equals(expected), reason: name);

          final data = Uint8List.fromList(built.bytes);
          data[built.blocks[1].checkOffset(size)] ^= 0xff;
          output = OutputFileStream(path);
          expect(
              () => XZDecoder().decodeStream(InputMemoryStream(data), output,
                  verify: true, throwOnError: true),
              throwsA(isA<ArchiveException>()
                  .having((e) => e.message, 'message', contains(reason))),
              reason: name);
          await output.close();
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('verifies CRC32 while streaming the output back', () async {
      final compressed = fixture('crc32');
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    test('verifies CRC64 while streaming the output back', () async {
      final compressed = fixture('crc64-blocks');
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    test('verifies SHA-256 while streaming output', () async {
      final compressed = fixture('sha256');
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    test('wrong SHA-256 check throws ArchiveException', () async {
      final built = buildArchive('sha256');
      final data = Uint8List.fromList(built.bytes);
      data[built.blocks[1].checkOffset(32)] ^= 0xff;
      expect(await decodeBytesOnIsolates(data, workers: 4), equals(expected));
      await expectLater(
          decodeStreamOnIsolates(InputMemoryStream(data), OutputMemoryStream(),
              verify: true, workers: 4),
          throwsA(isA<ArchiveChecksumException>()));
    });

    test(
        'truncated check field is reported as truncated archive, not wrong check',
        () async {
      final compressed = fixture('sha256');
      final cut = Uint8List.sublistView(compressed, 0, compressed.length - 130);
      final truncated = allOf(
          isA<ArchiveException>(), isNot(isA<ArchiveChecksumException>()));
      expect(
          () => XZDecoder().decodeBytes(cut, verify: true), throwsA(truncated));
      await expectLater(decodeBytesOnIsolates(cut, verify: true, workers: 2),
          throwsA(truncated));
      await expectLater(
          decodeStreamOnIsolates(InputMemoryStream(cut), OutputMemoryStream(),
              verify: true, workers: 2),
          throwsA(truncated));
    });

    group('corrupt archives', () {
      late Uint8List pristine;
      late List<BlockInfo> blocks;

      setUp(() {
        final built = buildArchive('blocks');
        pristine = built.bytes;
        blocks = built.blocks;
        // Several blocks, so that a corrupt one has intact neighbours.
        expect(blocks.length, greaterThan(4));
      });

      test('index uncompressed sizes that overflow sum throw ArchiveException',
          () async {
        final empty = emptyBlockStream();
        final block = empty.sublist(12, empty.length - 20);
        final length = [...List.filled(8, 0x80), 0x40];
        final records = <int>[0, 2, 17, ...length, 17, ...length];
        while (records.length % 4 != 0) {
          records.add(0);
        }
        final index = [...records, ..._uint32(getCrc32(records))];
        final backward = [..._uint32(index.length ~/ 4 - 1), 0, 1];
        final data = Uint8List.fromList([
          ...empty.sublist(0, 12),
          ...block,
          ...block,
          ...index,
          ..._uint32(getCrc32(backward)),
          ...backward,
          0x59,
          0x5a,
        ]);

        expect(
            XZDecoder(maxPreallocateSize: 0x7fffffffffffffff)
                .uncompressedSize(data),
            isNull);
        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        await expectLater(decodeBytesOnIsolates(data, verify: true, workers: 2),
            throwsA(isA<ArchiveException>()));
        expect(await decodeBytesOnIsolates(data, workers: 2), isEmpty);
      });

      test('error on main isolate follows verify and throwOnError', () async {
        expect(
            await decodeStreamOnIsolates(
                _ThrowingInput(pristine, RangeError('cut')),
                OutputMemoryStream(),
                workers: 2),
            isFalse);
        await expectLater(
            decodeStreamOnIsolates(_ThrowingInput(pristine, RangeError('cut')),
                OutputMemoryStream(),
                verify: true, workers: 2),
            throwsA(isA<ArchiveException>()));
        final failure = _ReadFailure();
        await expectLater(
            decodeStreamOnIsolates(
                _ThrowingInput(pristine, failure), OutputMemoryStream(),
                workers: 2),
            throwsA(same(failure)));
      });

      test('nonzero index padding with valid checksum throws', () async {
        final backward = ByteData.sublistView(pristine)
            .getUint32(pristine.length - 8, Endian.little);
        final size = (backward + 1) * 4;
        final start = pristine.length - 12 - size;
        expect(pristine[start + size - 5], 0);
        final data = Uint8List.fromList(pristine)..[start + size - 5] = 1;
        ByteData.sublistView(data).setUint32(start + size - 4,
            getCrc32(data.sublist(start, start + size - 4)), Endian.little);

        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        await expectLater(decodeBytesOnIsolates(data, verify: true, workers: 2),
            throwsA(isA<ArchiveException>()));
        await expectLater(
            decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                verify: true, workers: 2),
            throwsA(isA<ArchiveException>()));
      });

      test('excess zero index padding with valid checksum throws', () async {
        final backward = ByteData.sublistView(pristine)
            .getUint32(pristine.length - 8, Endian.little);
        final size = (backward + 1) * 4;
        final start = pristine.length - 12 - size;
        final records = [
          ...pristine.sublist(start, start + size - 4),
          0,
          0,
          0,
          0,
        ];
        final footer = [
          ..._uint32(backward + 1),
          ...pristine.sublist(pristine.length - 4, pristine.length - 2),
        ];
        final data = Uint8List.fromList([
          ...pristine.sublist(0, start),
          ...records,
          ..._uint32(getCrc32(records)),
          ..._uint32(getCrc32(footer)),
          ...footer,
          0x59,
          0x5a,
        ]);

        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        await expectLater(decodeBytesOnIsolates(data, verify: true, workers: 2),
            throwsA(isA<ArchiveException>()));
      });

      test('overlong index record count throws', () async {
        final backward = ByteData.sublistView(pristine)
            .getUint32(pristine.length - 8, Endian.little);
        final size = (backward + 1) * 4;
        final start = pristine.length - 12 - size;
        // The record count is one byte and the index ends with padding, so
        // writing the count in two bytes takes one padding byte and keeps the
        // index at the length in its footer
        expect(pristine[start], 0);
        expect(pristine[start + 1], blocks.length);
        expect(pristine[start + size - 5], 0);
        final data = Uint8List.fromList(pristine)
          ..[start + 1] = 0x80 | blocks.length
          ..[start + 2] = 0
          ..setRange(start + 3, start + size - 4, pristine, start + 2);
        ByteData.sublistView(data).setUint32(start + size - 4,
            getCrc32(data.sublist(start, start + size - 4)), Endian.little);

        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
        final completer = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => completer.complete(r),
              onError: (e, _) => completer.complete(e),
              workers: 4,
            ));
        expect(await completer.future, isA<ArchiveException>());
      });

      test('block shorter than its index record throws', () async {
        final backward = ByteData.sublistView(pristine)
            .getUint32(pristine.length - 8, Endian.little);
        final size = (backward + 1) * 4;
        final start = pristine.length - 12 - size;
        var at = start + 1;
        int readVli() {
          var value = 0;
          for (var shift = 0;; shift += 7) {
            final byte = pristine[at++];
            value |= (byte & 0x7f) << shift;
            if (byte < 0x80) {
              return value;
            }
          }
        }

        expect(readVli(), blocks.length);
        readVli();
        final field = at;
        final uncompressed = readVli() + 1;
        final data = Uint8List.fromList(pristine);
        for (var i = field, v = uncompressed; i < at; i++, v >>= 7) {
          data[i] = i + 1 < at ? 0x80 | (v & 0x7f) : v;
        }
        ByteData.sublistView(data).setUint32(start + size - 4,
            getCrc32(data.sublist(start, start + size - 4)), Endian.little);
        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));

        // Workers trusted index sizes, so this left zeros in decodeBytes
        // output and cut decodeStream short with success
        final fromBytes = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            verify: true,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => fromBytes.complete(r),
              onError: (e, _) => fromBytes.complete(e),
              workers: 4,
            ));
        expect(await fromBytes.future, isA<ArchiveException>());

        final dir = Directory.systemTemp.createTempSync('xz_index_size');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/a.xz';
        File(path).writeAsBytesSync(data);
        final input = InputFileStream(path);
        addTearDown(input.closeSync);
        final fromStream = Completer<Object?>();
        XZDecoder().decodeStream(input, OutputMemoryStream(),
            verify: true,
            throwOnError: true,
            multithread: XZMultithreadOptions<bool>(
              onDone: (r) => fromStream.complete(r),
              onError: (e, _) => fromStream.complete(e),
              workers: 4,
            ));
        expect(await fromStream.future, isA<ArchiveException>());
      });

      test('block whose compressed size differs from index throws', () async {
        final backward = ByteData.sublistView(pristine)
            .getUint32(pristine.length - 8, Endian.little);
        final size = (backward + 1) * 4;
        final start = pristine.length - 12 - size;
        var at = start + 1;
        int readVli() {
          var value = 0;
          for (var shift = 0;; shift += 7) {
            final byte = pristine[at++];
            value |= (byte & 0x7f) << shift;
            if (byte < 0x80) {
              return value;
            }
          }
        }

        expect(readVli(), blocks.length);
        final field = at;
        final unpadded = readVli();
        expect(unpadded % 4, isNot(0));
        final data = Uint8List.fromList(pristine);
        for (var i = field, v = unpadded + 1; i < at; i++, v >>= 7) {
          data[i] = i + 1 < at ? 0x80 | (v & 0x7f) : v;
        }
        ByteData.sublistView(data).setUint32(start + size - 4,
            getCrc32(data.sublist(start, start + size - 4)), Endian.little);
        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));

        final fromBytes = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            verify: true,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => fromBytes.complete(r),
              onError: (e, _) => fromBytes.complete(e),
              workers: 4,
            ));
        expect(await fromBytes.future, isA<ArchiveException>());

        final dir = Directory.systemTemp.createTempSync('xz_index_unpadded');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/a.xz';
        File(path).writeAsBytesSync(data);
        final input = InputFileStream(path);
        addTearDown(input.closeSync);
        final fromStream = Completer<Object?>();
        XZDecoder().decodeStream(input, OutputMemoryStream(),
            verify: true,
            throwOnError: true,
            multithread: XZMultithreadOptions<bool>(
              onDone: (r) => fromStream.complete(r),
              onError: (e, _) => fromStream.complete(e),
              workers: 4,
            ));
        expect(await fromStream.future, isA<ArchiveException>());
      });

      test(
          'block decoding past its index size does not overwrite next block output',
          () async {
        final data = Uint8List.fromList([
          for (final text in ['one\n', 'two\n', 'three\n'])
            ...XZEncoder().encodeBytes(Uint8List.fromList(text.codeUnits)),
        ]);
        final blocks = blocksOf(data);
        expect(blocks.length, 3);
        final at = blocks[0].dataOffset;
        expect(data[at], 1);
        data[at + 1] ^= 0x01;
        final results = <Uint8List>[];
        for (var run = 0; run < 4; run++) {
          final done = Completer<Uint8List>();
          XZDecoder().decodeBytes(data,
              multithread: XZMultithreadOptions<Uint8List>(
                onDone: done.complete,
                onError: (e, s) => done.completeError(e, s),
                workers: 4,
              ));
          results.add(await done.future);
        }
        for (final result in results) {
          expect(result.length, lessThanOrEqualTo(blocks[0].uncompSize));
          expect(result, results.first);
        }
      });

      test('truncated archive read from file throws instead of hanging',
          () async {
        final dir = Directory.systemTemp.createTempSync('xz_truncated');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/a.xz';
        for (final archive in [
          XZEncoder().encodeBytes(Uint8List(0)),
          XZEncoder().encodeBytes(Uint8List.fromList('hello'.codeUnits)),
        ]) {
          for (var length = 0; length < archive.length; length++) {
            File(path)
                .writeAsBytesSync(Uint8List.sublistView(archive, 0, length));
            final single = InputFileStream(path);
            expect(
                () => XZDecoder().decodeStream(single, OutputMemoryStream(),
                    verify: true, throwOnError: true),
                throwsA(isA<ArchiveException>()),
                reason: 'length $length');
            single.closeSync();

            final threaded = InputFileStream(path);
            final result = Completer<Object?>();
            XZDecoder().decodeStream(threaded, OutputMemoryStream(),
                verify: true,
                throwOnError: true,
                multithread: XZMultithreadOptions<bool>(
                  onDone: (r) => result.complete(r),
                  onError: (e, _) => result.complete(e),
                  workers: 2,
                ));
            expect(await result.future.timeout(const Duration(seconds: 10)),
                isA<ArchiveException>(),
                reason: 'length $length');
            threaded.closeSync();
          }
        }
      });

      test('file deleted before workers open it reports original error',
          () async {
        final dir = Directory.systemTemp.createTempSync('xz_gone');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/a.xz';
        File(path).writeAsBytesSync(pristine);
        final input = InputFileStream(path);
        addTearDown(input.closeSync);
        final result = Completer<Object?>();
        XZDecoder().decodeStream(input, OutputMemoryStream(),
            multithread: XZMultithreadOptions<bool>(
              onDone: (r) => result.complete(r),
              onError: (e, _) => result.complete(e),
              workers: 2,
            ));
        File(path).deleteSync();
        expect(await result.future.timeout(const Duration(seconds: 10)),
            isA<FileSystemException>());
      }, testOn: '!windows');

      group('input error in worker job', () {
        final archive = XZEncoder().encodeBytes(Uint8List(1000));
        final block = parseXZLayout(XZMemorySource(archive))!.blocks.single;
        final bytes = Uint8List.sublistView(archive, block.compressedOffset,
            block.compressedOffset + block.compressedLength);

        ({bool ok, String? reason}) decode(
                InputStream input, void Function() onPiece) =>
            xzDecodeJob(
                kind: xzKindBlock,
                input: input,
                data: null,
                length: bytes.length,
                streamFlags: block.streamFlags,
                verify: true,
                maxPreallocateSize: 1 << 20,
                outputOffset: 0,
                uncompressedLength: block.uncompressedLength,
                unpaddedLength: null,
                onPiece: (_, __) => onPiece());

        test('keeps error type while block decodes', () {
          final failure = _ReadFailure();
          final input = _FailingInput(bytes, failure)..armed = true;
          expect(() => decode(input, () {}), throwsA(same(failure)));
        });

        test('keeps error type while check field is read', () {
          final failure = _ReadFailure();
          final input = _FailingInput(bytes, failure,
              seekTo: bytes.length - xzCheckSize(block.streamFlags & 0xf));
          expect(() => decode(input, () {}), throwsA(same(failure)));
        });
      });

      test('range coder not starting at zero throws on workers', () async {
        final data = Uint8List.fromList(pristine);
        final at = blocks[1].dataOffset;
        expect(data[at], greaterThanOrEqualTo(0xe0));
        data[at + 6] ^= 0x01;
        expect(
            () =>
                XZDecoder().decodeBytes(data, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));

        final strict = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            verify: true,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => strict.complete(r),
              onError: (e, _) => strict.complete(e),
              workers: 4,
            ));
        expect(await strict.future, isA<ArchiveException>());
        await expectLater(
            const XzCodec(
                    multithread: XZMultithreadOptions.converter(workers: 4))
                .decoder
                .bind(Stream<List<int>>.value(data))
                .toList(),
            throwsA(isA<ArchiveException>()));

        final loose = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => loose.complete(r),
              onError: (e, _) => loose.complete(e),
              workers: 4,
            ));
        expect(await loose.future, isA<ArchiveException>());
        await expectLater(
            const XzCodec(
                    verify: false,
                    multithread: XZMultithreadOptions.converter(workers: 4))
                .decoder
                .bind(Stream<List<int>>.value(data))
                .toList(),
            throwsA(isA<ArchiveException>()));
      });

      // Whatever a failed decode hands back has to be genuine as far as it
      // goes: a prefix of the real data, never bytes that were never there.
      void expectGenuinePrefix(Uint8List result, String label) {
        expect(result.length, lessThanOrEqualTo(expected.length),
            reason: label);
        expect(
            result, equals(Uint8List.sublistView(expected, 0, result.length)),
            reason: label);
      }

      Uint8List damaged(int offset, [int runLength = 64]) {
        final data = Uint8List.fromList(pristine);
        for (var i = 0; i < runLength; i++) {
          data[offset + i] ^= 0xff;
        }
        return data;
      }

      // The output ends at the first failed block. Blocks after it are wasted
      // work. The second worker can hold one block when the failure arrives.
      // That one block is allowed to finish
      test('failed block stops pool from starting more blocks', () async {
        final data = damaged(blocks[0].dataOffset + 8);
        var failed = false;
        var afterFailure = 0;
        final ok = await xzDecodeMultithreaded(
          bytes: data,
          layout: parseXZLayout(XZMemorySource(data)),
          verify: true,
          maxPreallocateSize: expected.length,
          workers: 2,
          onChunk: (_, __) {},
          onBlockDone: (_, blockOk) {
            if (failed) {
              afterFailure++;
            }
            if (!blockOk) {
              failed = true;
            }
          },
          fileReadBufferSize: 0,
        );
        expect(ok, isFalse);
        expect(failed, isTrue);
        expect(blocks.length, greaterThan(4));
        expect(afterFailure, lessThanOrEqualTo(1));
      });

      test('throwOnError reports a bad block while the index still reads',
          () async {
        // Truncating an archive takes its index with it, which sends the
        // decode down the growing buffer path. Damaging a block in place
        // leaves the index readable, so the output is allocated up front from
        // it, and that is a separate place for the failure to be noticed.
        final data = damaged(blocks[1].dataOffset + 8);
        expect(XZDecoder().uncompressedSize(data), equals(expected.length));

        final completer = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => completer.complete(r),
              onError: (e, _) => completer.complete(e),
              workers: 4,
            ));
        expect(await completer.future, isA<ArchiveException>());

        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('a corrupt second block leaves the first one intact', () async {
        final data = damaged(blocks[1].dataOffset + 8);

        final sequential = XZDecoder().decodeBytes(data);
        final parallel = await decodeBytesOnIsolates(data, workers: 4);

        expectGenuinePrefix(sequential, 'sequential');
        expectGenuinePrefix(parallel, 'parallel');
        // The undamaged first block survives in both.
        expect(sequential.length, greaterThanOrEqualTo(blocks[1].uncompOffset));
        expect(parallel.length, greaterThanOrEqualTo(blocks[1].uncompOffset));
        // And neither pretends the rest of the archive decoded.
        expect(sequential.length, lessThan(expected.length));
        expect(parallel.length, lessThan(expected.length));

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt first block fails both modes', () async {
        final data = damaged(blocks[0].dataOffset + 8);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt block is caught with verify even at the last byte',
          () async {
        // Only the check field is damaged, so the data still decodes. Nothing
        // but the checksum can tell that this archive is not what was stored.
        final data = damaged(blocks[1].checkOffset(8), 8);

        // Without verification both modes decode it happily, as documented.
        expect(XZDecoder().decodeBytes(data), equals(expected));
        expect(await decodeBytesOnIsolates(data, workers: 4), equals(expected));

        // With verification both refuse it.
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(data), OutputMemoryStream(),
                verify: true),
            throwsA(isA<ArchiveChecksumException>()));
        await expectLater(
            decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                verify: true, workers: 4),
            throwsA(isA<ArchiveChecksumException>()));

        // Both stop in the same place, and that place is the end of the block
        // whose check failed: writing straight through to an output stream
        // cannot take those bytes back, so the single threaded decode leaves
        // them behind and the parallel one matches it rather than inventing a
        // stricter rule for itself. Neither vouches for them; both reported
        // the failure above.
        final sequential = OutputMemoryStream();
        expect(
            () => XZDecoder().decodeStream(InputMemoryStream(data), sequential,
                verify: true),
            throwsA(isA<ArchiveChecksumException>()));
        final parallel = OutputMemoryStream();
        await expectLater(
            decodeStreamOnIsolates(InputMemoryStream(data), parallel,
                verify: true, workers: 4),
            throwsA(isA<ArchiveChecksumException>()));
        expectGenuinePrefix(sequential.getBytes(), 'sequential');
        expectGenuinePrefix(parallel.getBytes(), 'parallel');
        expect(parallel.length, equals(sequential.length));
        expect(parallel.length,
            equals(blocks[1].uncompOffset + blocks[1].uncompSize));
      });

      test('verify reports check failure of first block when next is damaged',
          () async {
        final data = damaged(blocks[0].checkOffset(8), 8);
        data[blocks[1].dataOffset] = 0x03;

        expect(() => XZDecoder().decodeBytes(data, verify: true),
            throwsA(isA<ArchiveChecksumException>()));
        for (var round = 0; round < 10; round++) {
          await expectLater(
              decodeBytesOnIsolates(data, verify: true, workers: 4),
              throwsA(isA<ArchiveChecksumException>()),
              reason: 'round $round');
        }
      });

      test('a truncated archive fails both modes', () async {
        // The index and the footer are gone, so the layout cannot be read and
        // the parallel path has to fall back to decoding the stream whole.
        final data = Uint8List.sublistView(pristine, 0, pristine.length - 40);
        expect(XZDecoder().uncompressedSize(data), isNull);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt index falls back and still fails cleanly', () async {
        // Land inside the index, which sits between the last block and the
        // twelve byte footer.
        final data = damaged(pristine.length - 12 - 8, 4);
        expect(XZDecoder().uncompressedSize(data), isNull);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt block in a file source behaves the same', () async {
        final data = damaged(blocks[2].dataOffset + 8);
        final dir = Directory.systemTemp.createTempSync('archive_xz_corrupt');
        try {
          final archivePath = p.join(dir.path, 'data.xz');
          File(archivePath).writeAsBytesSync(data);

          final input = InputFileStream(archivePath);
          final output = OutputFileStream(p.join(dir.path, 'out.bin'));
          final ok = await decodeStreamOnIsolates(input, output, workers: 4);
          await input.close();
          await output.close();

          expect(ok, isFalse);
          expectGenuinePrefix(
              File(p.join(dir.path, 'out.bin')).readAsBytesSync(), 'file');
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    });

    test('decodeStream on workers reads input to end', () async {
      final compressed = fixture('blocks');
      final memory = InputMemoryStream(compressed);
      expect(
          await decodeStreamOnIsolates(memory, OutputMemoryStream(),
              workers: 2),
          isTrue);
      expect(memory.isEOS, isTrue);

      final file = InputFileStream('test/_data/xz/parallel/blocks.xz');
      final ok =
          await decodeStreamOnIsolates(file, OutputMemoryStream(), workers: 2);
      final eos = file.isEOS;
      await file.close();
      expect(ok, isTrue);
      expect(eos, isTrue);
    });

    test('one worker still decodes the whole archive', () async {
      final compressed = fixture('blocks');
      expect(await decodeBytesOnIsolates(compressed, workers: 1),
          equals(expected));
    });

    test(
        '1 worker decodes 2 blocks when second starts on staging buffer boundary',
        () async {
      final part = XZEncoder().encodeBytes(Uint8List(xzStagingSize));
      final compressed = Uint8List.fromList([...part, ...part]);
      final output = OutputMemoryStream();
      expect(
          await decodeStreamOnIsolates(InputMemoryStream(compressed), output,
              workers: 1),
          isTrue);
      expect(output.length, equals(2 * xzStagingSize));

      final completer = Completer<Uint8List>();
      XZDecoder(maxPreallocateSize: 0).decodeBytes(compressed,
          multithread: XZMultithreadOptions(
            onDone: completer.complete,
            onError: completer.completeError,
            workers: 1,
          ));
      expect(await completer.future, hasLength(2 * xzStagingSize));
    });

    test('empty block does not drop blocks after it', () async {
      final first =
          XZEncoder().encodeBytes(Uint8List(300000)..fillRange(0, 300000, 1));
      final last =
          XZEncoder().encodeBytes(Uint8List(300000)..fillRange(0, 300000, 2));
      final compressed =
          Uint8List.fromList([...first, ...emptyBlockStream(), ...last]);
      final whole = XZDecoder().decodeBytes(compressed, verify: true);
      expect(whole, hasLength(600000));

      final output = OutputMemoryStream();
      expect(
          await decodeStreamOnIsolates(InputMemoryStream(compressed), output,
              workers: 2),
          isTrue);
      expect(output.getBytes(), equals(whole));

      final completer = Completer<Uint8List>();
      XZDecoder(maxPreallocateSize: 0).decodeBytes(compressed,
          multithread: XZMultithreadOptions(
            onDone: completer.complete,
            onError: completer.completeError,
            workers: 2,
          ));
      expect(await completer.future, equals(whole));
    });

    test('a worker count above the core count is clamped, not rejected',
        () async {
      final compressed = fixture('blocks');
      expect(await decodeBytesOnIsolates(compressed, workers: 999),
          equals(expected));
    });

    test('a memory budget too small for two workers still decodes', () async {
      final compressed = fixture('blocks');
      expect(
          await decodeBytesOnIsolates(compressed, workers: 8, memoryBudget: 1),
          equals(expected));
    });

    test('rejects settings that cannot be honoured', () {
      // These all feed the arithmetic that sizes the pool, where a nonsense
      // value does not fail loudly. A negative read buffer in particular makes
      // the per worker cost come out negative, which skips the memory budget
      // and hands out more workers than the budget allows.
      final compressed = fixture('blocks');
      final cases = <String, XZMultithreadOptions<Uint8List>>{
        'workers: 0': XZMultithreadOptions(onDone: (_) {}, workers: 0),
        'workers: -1': XZMultithreadOptions(onDone: (_) {}, workers: -1),
        'memoryBudget: 0':
            XZMultithreadOptions(onDone: (_) {}, memoryBudget: 0),
        'memoryBudget: -1':
            XZMultithreadOptions(onDone: (_) {}, memoryBudget: -1),
        'fileReadBufferSize: 0':
            XZMultithreadOptions(onDone: (_) {}, fileReadBufferSize: 0),
        'fileReadBufferSize negative': XZMultithreadOptions(
            onDone: (_) {}, fileReadBufferSize: -300000000),
      };
      cases.forEach((label, options) {
        expect(() => XZDecoder().decodeBytes(compressed, multithread: options),
            throwsArgumentError,
            reason: label);
      });
    });

    test('accepts the smallest settings that make sense', () async {
      final compressed = fixture('blocks');
      final completer = Completer<Uint8List>();
      XZDecoder().decodeBytes(compressed,
          multithread: XZMultithreadOptions(
            onDone: completer.complete,
            onError: completer.completeError,
            workers: 1,
            memoryBudget: 1,
            fileReadBufferSize: 1,
          ));
      expect(await completer.future, equals(expected));
    });

    test('a single block archive still reports through onDone', () async {
      final compressed = fixture('whole');
      expect(await decodeBytesOnIsolates(compressed), equals(expected));
    });

    test('decodes concatenated streams', () async {
      final file = File(p.join('test/_data/xz/hello-hello-hello.xz'));
      final compressed = file.readAsBytesSync();
      expect(await decodeBytesOnIsolates(compressed),
          equals(XZDecoder().decodeBytes(compressed)));
    });

    test('decodes every archive in the test data the same way', () async {
      final dir = Directory('test/_data/xz');
      for (final entry in dir.listSync()) {
        if (entry is! File || !entry.path.endsWith('.xz')) {
          continue;
        }
        final compressed = entry.readAsBytesSync();
        final sequential = XZDecoder().decodeBytes(compressed);
        final parallel = await decodeBytesOnIsolates(compressed);
        expect(parallel, equals(sequential), reason: entry.path);
      }
    });

    test('damaged index gives same partial output as on 1 thread', () async {
      final compressed =
          File('test/_data/xz/bad-2-index-1.xz').readAsBytesSync();
      expect(await decodeBytesOnIsolates(compressed),
          XZDecoder().decodeBytes(compressed));
    });

    test('uncompressedSize agrees with what is decoded', () {
      final dir = Directory('test/_data/xz');
      for (final entry in dir.listSync()) {
        if (entry is! File || !entry.path.endsWith('.xz')) {
          continue;
        }
        final compressed = entry.readAsBytesSync();
        final size = XZDecoder().uncompressedSize(compressed);
        if (size == null) {
          continue;
        }
        // Some of the archives here are deliberately corrupt in their payload
        // while carrying an intact index, so the size is readable even though
        // the data is not.
        if (!XZDecoder().decodeStream(
            InputMemoryStream(compressed), OutputMemoryStream())) {
          continue;
        }
        expect(size, equals(XZDecoder().decodeBytes(compressed).length),
            reason: entry.path);
      }
    });

    test('streams a file straight from disk into a file', () async {
      final compressed = fixture('blocks');
      final dir = Directory.systemTemp.createTempSync('archive_xz_files');
      try {
        final archivePath = p.join(dir.path, 'data.xz');
        File(archivePath).writeAsBytesSync(compressed);
        final outputPath = p.join(dir.path, 'data.bin');

        final input = InputFileStream(archivePath);
        final output = OutputFileStream(outputPath);
        final ok = await decodeStreamOnIsolates(input, output, workers: 4);
        await input.close();
        await output.close();

        expect(ok, isTrue);
        expect(File(outputPath).readAsBytesSync(), equals(expected));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('repeated file decodes do not leak file handles', () async {
      // A killed isolate does not release its file descriptors, so a worker
      // that kept the archive open between blocks would leak four a round.
      // Enough rounds and that runs the process out of descriptors, and the
      // round that cannot open the archive fails here: no tool has to be asked
      // how many are open, the limit answers
      final dir = Directory.systemTemp.createTempSync('archive_xz_handles');
      try {
        final archivePath = p.join(dir.path, 'data.xz');
        File(archivePath).writeAsBytesSync(fixture('blocks'));
        final outputPath = p.join(dir.path, 'data.bin');

        for (var round = 0; round < 256; round++) {
          final input = InputFileStream(archivePath);
          final output = OutputFileStream(outputPath);
          final ok = await decodeStreamOnIsolates(input, output, workers: 4);
          await input.close();
          await output.close();
          expect(ok, isTrue, reason: 'round $round');
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('splits an archive whose output is too large to preallocate',
        () async {
      // Above the preallocation ceiling, decodeBytes grows its buffer instead of
      // trusting the index size, but blocks still go to multiple isolates: falling
      // back to one was ~9x slower on a 3 GB archive.
      //
      // Off by default. It allocates over three gigabytes. Zeros compress at
      // ratios in the thousands, so the fixture itself stays small
      final compressed = fixture('huge');
      // Beyond the ceiling the size is not reported at all
      expect(XZDecoder().uncompressedSize(compressed), isNull);

      final decoded = await decodeBytesOnIsolates(compressed, workers: 4);
      expect(decoded.length, equals(48 * 64 * 1024 * 1024));
      expect(decoded[0], 0);
      expect(decoded[decoded.length - 1], 0);
    },
        skip: Platform.environment['ARCHIVE_SLOW_TESTS'] == null
            ? 'set ARCHIVE_SLOW_TESTS=1 to run; needs over 3 GB of memory'
            : null);

    test('exposes the file region a stream reads from', () {
      final compressed = fixture('blocks');
      final dir = Directory.systemTemp.createTempSync('archive_xz_region');
      try {
        final path = p.join(dir.path, 'data.xz');
        File(path).writeAsBytesSync(compressed);

        // These are what let the decoder find the file behind a stream and
        // hand disjoint ranges of it to isolates.
        final whole = InputFileStream(path);
        expect(whole.fileOffset, 0);
        expect(whole.fileLength, compressed.length);
        expect(whole.fileBuffer.length, compressed.length);

        final part =
            InputFileStream.fromFileStream(whole, position: 64, length: 128);
        expect(part.fileOffset, 64);
        expect(part.fileLength, 128);

        whole.closeSync();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('falls back for a stream that is neither memory nor a file', () async {
      // A RAM backed file stream has no path for workers to read, so it is
      // documented to decode on the calling isolate, still reporting through
      // onDone.
      final compressed = fixture('blocks');
      final input = await InputFileStream.asRamFile(
          Stream.value(compressed), compressed.length);
      final output = OutputMemoryStream();

      final ok = await decodeStreamOnIsolates(input, output, workers: 4);

      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });

    test('keeps the same partial output when a block fails while verifying',
        () async {
      // To verify a CRC32 or CRC64 check the decoder keeps the block, so it
      // can sum it afterwards. We used to drop that buffer when the block
      // failed part way through, but only for an output we cannot read back.
      // Writing to memory took the other branch and kept what had decoded.
      // Workers always write to a port, so a corrupt archive gave nothing on
      // isolates and a partial result without them
      final source = fixture('crc64');
      final full = XZDecoder().decodeBytes(source).length;

      // Cutting the archive in half leaves a block that decodes for a while
      // and then runs out of input, which is the shape being tested and does
      // not depend on where a particular xz build put its chunk boundaries.
      final compressed = Uint8List.sublistView(source, 0, source.length ~/ 2);
      final partial = XZDecoder().decodeBytes(compressed).length;
      expect(partial, greaterThan(0));
      expect(partial, lessThan(full));

      // Every way of asking has to stop in the same place, whether or not the
      // check is verified and whether or not the output can be read back.
      expect(await decodeBytesOnIsolates(compressed), hasLength(partial));
      final verified = OutputMemoryStream();
      expect(
          () => XZDecoder().decodeStream(
              InputMemoryStream(compressed), verified,
              verify: true),
          throwsA(isA<ArchiveException>()));
      expect(verified.length, equals(partial));
      await expectLater(decodeBytesOnIsolates(compressed, verify: true),
          throwsA(isA<ArchiveException>()));

      final dir = Directory.systemTemp.createTempSync('archive_xz_partial');
      try {
        for (final verify in [false, true]) {
          final path = p.join(dir.path, 'out_$verify.bin');
          final output = OutputFileStream(path);
          if (verify) {
            expect(
                () => XZDecoder().decodeStream(
                    InputMemoryStream(compressed), output,
                    verify: verify),
                throwsA(isA<ArchiveException>()));
          } else {
            expect(
                XZDecoder().decodeStream(InputMemoryStream(compressed), output,
                    verify: verify),
                isFalse);
          }
          await output.close();
          expect(File(path).lengthSync(), equals(partial),
              reason: 'sync, verify: $verify');
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    group('archive wrapper', () {
      // Splitting an archive up means finding the blocks through the index and
      // decoding each one on its own, so nothing afterwards ever looks at the
      // stream header or footer again. Whatever the single threaded decode
      // checks in them has to be checked here instead, or a damaged archive
      // that xz rejects decodes without complaint.
      late Uint8List pristine;

      setUp(() {
        pristine = fixture('crc64-blocks');
        expect(XZDecoder().uncompressedSize(pristine), equals(expected.length));
      });

      Uint8List flipped(int offset) {
        final data = Uint8List.fromList(pristine);
        data[offset] ^= 0xff;
        return data;
      }

      test('rejects a damaged stream header CRC', () async {
        // Bytes 8..11 of the archive. They cover the two flag bytes in front
        // of them and nothing else reads them.
        for (var i = 8; i < 12; i++) {
          final data = flipped(i);
          expect(XZDecoder().uncompressedSize(data), isNull, reason: 'byte $i');
          expect(
              await decodeStreamOnIsolates(
                  InputMemoryStream(data), OutputMemoryStream(),
                  workers: 4),
              isFalse,
              reason: 'byte $i');
        }
      });

      test('rejects a damaged stream footer CRC', () async {
        // The last twelve bytes are the footer, and its CRC32 leads.
        final footerStart = pristine.length - 12;
        for (var i = footerStart; i < footerStart + 4; i++) {
          final data = flipped(i);
          expect(XZDecoder().uncompressedSize(data), isNull, reason: 'byte $i');
          expect(
              await decodeStreamOnIsolates(
                  InputMemoryStream(data), OutputMemoryStream(),
                  workers: 4),
              isFalse,
              reason: 'byte $i');
        }
      });

      test('agrees with the single threaded decode on every wrapper byte',
          () async {
        // The header, the footer and the index between them. Damaging any one
        // byte has to reach the same verdict either way, which is the property
        // the two tests above are specific cases of.
        final offsets = <int>[
          for (var i = 0; i < 12; i++) i,
          for (var i = pristine.length - 64; i < pristine.length; i++) i,
        ];
        for (final i in offsets) {
          final data = flipped(i);
          final sequential = XZDecoder()
              .decodeStream(InputMemoryStream(data), OutputMemoryStream());
          final parallel = await decodeStreamOnIsolates(
              InputMemoryStream(data), OutputMemoryStream(),
              workers: 4);
          expect(parallel, equals(sequential), reason: 'byte $i');
        }
      });
    });

    group('throwOnError', () {
      // The exception cannot reach the caller, whose stack is gone by the time
      // the workers finish, so it is delivered to onError instead. Without the
      // flag a corrupt archive is not an error and reaches onDone.
      late Uint8List broken;
      late Uint8List whole;

      setUpAll(() {
        whole = fixture('blocks');
        broken = Uint8List.sublistView(whole, 0, whole.length ~/ 2);
      });

      /// Runs a decode and reports which callback it ended up in.
      Future<({Object? error, Object? done})> outcome(
          void Function(void Function(Object? done) onDone,
                  void Function(Object, StackTrace) onError)
              start) {
        final completer = Completer<({Object? error, Object? done})>();
        start(
          (done) => completer.complete((error: null, done: done)),
          (error, _) => completer.complete((error: error, done: null)),
        );
        return completer.future;
      }

      Future<({Object? error, Object? done})> bytes(Uint8List compressed,
              {required bool throwOnError, bool verify = false}) =>
          outcome((onDone, onError) => XZDecoder().decodeBytes(compressed,
              verify: verify,
              throwOnError: throwOnError,
              multithread: XZMultithreadOptions<Uint8List>(
                onDone: onDone,
                onError: onError,
                workers: 4,
              )));

      Future<({Object? error, Object? done})> stream(Uint8List compressed,
              {required bool throwOnError, bool verify = false}) =>
          outcome((onDone, onError) => XZDecoder()
              .decodeStream(InputMemoryStream(compressed), OutputMemoryStream(),
                  verify: verify,
                  throwOnError: throwOnError,
                  multithread: XZMultithreadOptions<bool>(
                    onDone: onDone,
                    onError: onError,
                    workers: 4,
                  )));

      test('decodeBytes routes a corrupt archive to onError', () async {
        final r = await bytes(broken, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('decodeBytes without it reports the partial output to onDone',
          () async {
        final r = await bytes(broken, throwOnError: false);
        expect(r.error, isNull);
        expect(r.done, isA<Uint8List>());
        expect(r.done as Uint8List, isNotEmpty);
        expect((r.done as Uint8List).length, lessThan(expected.length));
      });

      test('decodeBytes stays on onDone for a valid archive', () async {
        final r = await bytes(whole, throwOnError: true);
        expect(r.error, isNull);
        expect(r.done, equals(expected));
      });

      test('decodeStream routes a corrupt archive to onError', () async {
        final r = await stream(broken, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('decodeStream without it reports false to onDone', () async {
        final r = await stream(broken, throwOnError: false);
        expect(r.error, isNull);
        expect(r.done, isFalse);
      });

      test('decodeStream stays on onDone for a valid archive', () async {
        final r = await stream(whole, throwOnError: true);
        expect(r.error, isNull);
        expect(r.done, isTrue);
      });

      test('reaches onError while verifying too', () async {
        expect((await bytes(broken, throwOnError: true, verify: true)).error,
            isA<ArchiveException>());
        expect((await stream(broken, throwOnError: true, verify: true)).error,
            isA<ArchiveException>());
      });

      test('reaches onError on a single block archive as well', () async {
        // One block is decoded whole on one isolate rather than being split,
        // which is a separate path through the worker.
        final single = fixture('whole');
        final r = await bytes(
            Uint8List.sublistView(single, 0, single.length ~/ 2),
            throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('reaches onError for a file the workers read themselves', () async {
        final dir = Directory.systemTemp.createTempSync('archive_xz_throw');
        try {
          final archivePath = p.join(dir.path, 'data.xz');
          File(archivePath).writeAsBytesSync(broken);
          final input = InputFileStream(archivePath);
          final output = OutputFileStream(p.join(dir.path, 'out.bin'));
          final r = await outcome(
              (onDone, onError) => XZDecoder().decodeStream(input, output,
                  throwOnError: true,
                  multithread: XZMultithreadOptions<bool>(
                    onDone: onDone,
                    onError: onError,
                    workers: 4,
                  )));
          await input.close();
          await output.close();
          expect(r.error, isA<ArchiveException>());
          expect(r.done, isNull);
        } finally {
          dir.deleteSync(recursive: true);
        }
      });

      test('carries the reason back out of the workers', () async {
        // The reason is worked out inside an isolate, so it has to survive the
        // trip home; without that the caller is told only that something was
        // wrong somewhere.
        final notXz = Uint8List.fromList(
            List<int>.generate(200000, (i) => (i * 37) & 0xff));
        final r = await bytes(notXz, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect((r.error as ArchiveException).message,
            contains('Invalid XZ stream header signature'));

        // And a failure that is about the data rather than the wrapper. The
        // check of a block sits at its end, so breaking that alone leaves the
        // data itself decodable and only a verifying decode objects.
        final built = buildArchive('crc64-blocks');
        final badCheck = Uint8List.fromList(built.bytes);
        badCheck[built.blocks[0].checkOffset(8)] ^= 0xff;
        expect(
            await decodeBytesOnIsolates(badCheck, workers: 4), equals(expected),
            reason: 'only the stored check should be broken');

        final checked = await bytes(badCheck, throwOnError: true, verify: true);
        expect(checked.error, isA<ArchiveException>());
        expect((checked.error as ArchiveException).message,
            contains('check failed'));
      });

      test('is refused when there is nowhere to deliver the exception', () {
        // Asking to be told and leaving no onError would put the failure back
        // where it started, so it is rejected while the caller can still hear.
        for (final (verify, throwOnError) in [(false, true), (true, false)]) {
          expect(
              () => XZDecoder().decodeBytes(broken,
                  verify: verify,
                  throwOnError: throwOnError,
                  multithread: XZMultithreadOptions(onDone: (_) {})),
              throwsArgumentError);
          expect(
              () => XZDecoder().decodeStream(
                  InputMemoryStream(broken), OutputMemoryStream(),
                  verify: verify,
                  throwOnError: throwOnError,
                  multithread: XZMultithreadOptions(onDone: (_) {})),
              throwsArgumentError);
        }
      });

      test('omitting onError is still fine without it', () async {
        final completer = Completer<Uint8List>();
        XZDecoder().decodeBytes(broken,
            multithread: XZMultithreadOptions<Uint8List>(
                onDone: completer.complete, workers: 4));
        expect(await completer.future, isNotEmpty);
      });
    });

    group('a block that outgrows its record in the index', () {
      // Damage inside a block header can raise the uncompressed size it
      // declares, leaving it larger than what the index records for that block.
      // decodeBytes preallocates from the index, so such a block has more to
      // write than the buffer holds. That has to be reported the way every
      // other damaged archive is, not raised from inside the chunk callback:
      // the caller's stack is gone by then, so a throw would arrive as a bare
      // RangeError even when failures were asked for by return value.
      //
      // The offsets come from test/_data/xz/good-1-lzma2-1.xz, which is
      // checked in, so they do not move. 31 of its 424 bytes have this effect.
      // These two are the first one and the one that overshoots furthest
      late Uint8List original;

      setUpAll(() {
        original = File('test/_data/xz/good-1-lzma2-1.xz').readAsBytesSync();
      });

      Uint8List damagedAt(int offset) {
        final data = Uint8List.fromList(original);
        data[offset] ^= 0xFF;
        return data;
      }

      for (final offset in const [240, 316]) {
        test('at byte $offset reaches onDone without throwOnError', () async {
          final data = damagedAt(offset);
          final declared = XZDecoder().uncompressedSize(data)!;
          // The premise: the single threaded decode really does produce more
          // than the index accounts for, which is what has nowhere to go.
          expect(XZDecoder().decodeBytes(data).length, greaterThan(declared));

          final completer = Completer<({Object? error, Uint8List? done})>();
          XZDecoder().decodeBytes(data,
              multithread: XZMultithreadOptions<Uint8List>(
                workers: 4,
                onDone: (d) => completer.complete((error: null, done: d)),
                onError: (e, _) => completer.complete((error: e, done: null)),
              ));
          final result = await completer.future;
          expect(result.error, isNull,
              reason: 'a corrupt archive is not an error without throwOnError');
          // Clipped at the index, which is the size the buffer was allocated
          // against and the only one of the two the archive can be held to.
          expect(result.done, hasLength(declared));
        });

        test('at byte $offset reports the mismatch with throwOnError',
            () async {
          final data = damagedAt(offset);
          final completer = Completer<Object?>();
          XZDecoder().decodeBytes(data,
              throwOnError: true,
              multithread: XZMultithreadOptions<Uint8List>(
                workers: 4,
                onDone: (_) => completer.complete(null),
                onError: (e, _) => completer.complete(e),
              ));
          final error = await completer.future;
          expect(error, isA<ArchiveException>());
          // The same reason the single threaded decode gives, rather than the
          // RangeError of a buffer that ran out of room. Damage this far into
          // the block is caught by the range coder at the end of the chunk,
          // before the index it disagrees with is ever read.
          expect((error as ArchiveException).message,
              contains('LZMA data is corrupt'));
        });
      }

      test('decodeStream is unaffected, because its output can grow', () async {
        final data = damagedAt(316);
        final sequential = OutputMemoryStream();
        final sequentialOk =
            XZDecoder().decodeStream(InputMemoryStream(data), sequential);

        final parallel = OutputMemoryStream();
        final completer = Completer<bool>();
        XZDecoder().decodeStream(InputMemoryStream(data), parallel,
            multithread: XZMultithreadOptions<bool>(
              workers: 4,
              onDone: completer.complete,
              onError: (e, _) => completer.completeError(e),
            ));

        expect(await completer.future, equals(sequentialOk));
        expect(parallel.getBytes(), equals(sequential.getBytes()));
      });
    });

    test('streams memory into a memory stream in block order', () async {
      final compressed = fixture('blocks');
      final output = OutputMemoryStream();
      final ok = await decodeStreamOnIsolates(
          InputMemoryStream(compressed), output,
          workers: 4);
      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });

    // The pull decoder, the converter and the isolate pool are three readers of
    // the same header bytes, and a check that lives in one of them shows up
    // here as a disagreement. The block header carries the fields the wrapper
    // sweep above never reaches: the block flags and the filter properties
    group('damaged archive gives same result on every decode path', () {
      late Uint8List pristine;
      late List<int> offsets;

      setUpAll(() {
        pristine = fixture('blocks');
        final blockHeader = (pristine[12] + 1) * 4;
        offsets = <int>[
          for (var i = 0; i < 12; i++) i,
          for (var i = 12; i < 12 + blockHeader; i++) i,
          for (var i = 12 + blockHeader; i < pristine.length - 64; i += 4093) i,
          for (var i = pristine.length - 64; i < pristine.length; i++) i,
        ];
      });

      bool pull(Uint8List data, OutputStream output) {
        try {
          return XZDecoder()
              .decodeStream(InputMemoryStream(data), output, verify: true);
        } on ArchiveException {
          return false;
        }
      }

      Future<bool> pullParallel(Uint8List data, OutputStream output) async {
        try {
          return await decodeStreamOnIsolates(InputMemoryStream(data), output,
              verify: true, workers: 4);
        } on ArchiveException {
          return false;
        }
      }

      bool push(Uint8List data, BytesBuilder output) {
        try {
          final sink = xzCodec.decoder.startChunkedConversion(
              ByteConversionSink.withCallback(output.add));
          for (var at = 0; at < data.length; at += 4096) {
            final end = at + 4096 < data.length ? at + 4096 : data.length;
            sink.add(Uint8List.sublistView(data, at, end));
          }
          sink.close();
          return true;
        } catch (_) {
          return false;
        }
      }

      test('every changed wrapper, block header and sampled payload byte',
          () async {
        for (final at in offsets) {
          final data = Uint8List.fromList(pristine)..[at] ^= 0xff;

          final sequential = OutputMemoryStream();
          final sequentialOk = pull(data, sequential);
          final chunked = BytesBuilder();
          final chunkedOk = push(data, chunked);
          final parallelOut = OutputMemoryStream();
          final parallelOk = await pullParallel(data, parallelOut);

          expect(chunkedOk, equals(sequentialOk),
              reason: 'byte $at, converter');
          expect(parallelOk, equals(sequentialOk), reason: 'byte $at, workers');
          if (sequentialOk) {
            expect(sequential.getBytes(), equals(expected), reason: 'byte $at');
            expect(chunked.toBytes(), equals(expected), reason: 'byte $at');
            expect(parallelOut.getBytes(), equals(expected),
                reason: 'byte $at');
          }
        }
      });

      test('reserved flag bit throws on every decode path', () async {
        final blockHeader = (pristine[12] + 1) * 4;
        final cases = <String, Uint8List>{
          'stream flags': Uint8List.fromList(pristine)..[7] |= 0x10,
          'block flags': Uint8List.fromList(pristine)..[13] |= 0x04,
        };
        for (final entry in cases.entries) {
          final data = entry.value;
          // The CRC would catch these first, so it is recomputed
          final view = ByteData.sublistView(data);
          if (entry.key == 'stream flags') {
            view.setUint32(8, getCrc32(data.sublist(6, 8)), Endian.little);
          } else {
            view.setUint32(
                12 + blockHeader - 4,
                getCrc32(data.sublist(12, 12 + blockHeader - 4)),
                Endian.little);
          }
          expect(pull(data, OutputMemoryStream()), isFalse, reason: entry.key);
          expect(push(data, BytesBuilder()), isFalse, reason: entry.key);
          expect(await pullParallel(data, OutputMemoryStream()), isFalse,
              reason: entry.key);
        }
      });
    });
  });

  // The converter on isolates has to write what the converter on one thread
  // writes, and on a failure no more than the whole blocks before it
  group('xz stream decoder on workers', () {
    final expected = sampleData(1200000);
    const options = XZMultithreadOptions<Object?>.converter(workers: 4);

    Stream<List<int>> pieces(Uint8List bytes, int size) async* {
      for (var at = 0; at < bytes.length; at += size) {
        final end = at + size < bytes.length ? at + size : bytes.length;
        yield Uint8List.sublistView(bytes, at, end);
      }
    }

    Future<({Uint8List bytes, Object? error})> collect(
        Stream<List<int>> stream) async {
      final out = BytesBuilder(copy: false);
      try {
        await for (final piece in stream) {
          out.add(piece);
        }
        return (bytes: out.toBytes(), error: null);
      } catch (error) {
        return (bytes: out.toBytes(), error: error);
      }
    }

    Future<({Uint8List bytes, Object? error})> threaded(Stream<List<int>> s,
            [XZMultithreadOptions<Object?> with_ = options]) =>
        collect(s.transform(XzCodec(multithread: with_).decoder))
            .timeout(const Duration(seconds: 60));

    Future<({Uint8List bytes, Object? error})> single(Stream<List<int>> s) =>
        collect(s.transform(xzCodec.decoder));

    bool isPrefix(List<int> part, List<int> whole) {
      if (part.length > whole.length) {
        return false;
      }
      for (var i = 0; i < part.length; i++) {
        if (part[i] != whole[i]) {
          return false;
        }
      }
      return true;
    }

    // Two failed decodes each stop somewhere in the true output, so they agree
    // as far as the shorter one goes. Neither has to be the longer one: the
    // single threaded sink loses what it gathered when it fails
    bool agreeSoFar(List<int> a, List<int> b) =>
        a.length <= b.length ? isPrefix(a, b) : isPrefix(b, a);

    test('every archive decodes same as on 1 thread', () async {
      final files = [
        ...Directory('test/_data/xz/parallel').listSync(),
        ...Directory('test/_data/xz').listSync(),
      ]
          .whereType<File>()
          .where((f) => f.path.endsWith('.xz') && !f.path.endsWith('huge.xz'));
      for (final file in files) {
        final bytes = file.readAsBytesSync();
        for (final size in [4096, 1 << 16, bytes.length + 1]) {
          final one = await single(pieces(bytes, size));
          final many = await threaded(pieces(bytes, size));
          final label = '${file.path} in pieces of $size';
          expect(many.error == null, one.error == null, reason: label);
          if (one.error == null) {
            expect(many.bytes, one.bytes, reason: label);
          } else {
            expect(agreeSoFar(many.bytes, one.bytes), isTrue, reason: label);
          }
        }
      }
    });

    test('input in 1-byte pieces decodes same as on 1 thread', () async {
      for (final name in ['x86.xz', 'concatenated.xz', 'stream_padding.xz']) {
        final bytes = File('test/_data/xz/$name').readAsBytesSync();
        expect((await threaded(pieces(bytes, 1))).bytes,
            (await single(pieces(bytes, 1))).bytes,
            reason: name);
      }
    });

    test('blocks without declared sizes keep their order between sized blocks',
        () async {
      // A stream whose blocks declare their lengths, one whose blocks do not,
      // and another that does, back to back
      final bytes = Uint8List.fromList([
        ...fixture('blocks'),
        ...File('test/_data/xz/crc32.xz').readAsBytesSync(),
        ...fixture('x86'),
      ]);
      final one = await single(pieces(bytes, 1 << 16));
      expect(one.error, isNull);
      final many = await threaded(pieces(bytes, 1 << 16));
      expect(many.error, isNull);
      expect(many.bytes, one.bytes);
    });

    test('memory budget for 1 worker gives same output', () async {
      final bytes = fixture('blocks');
      final many = await threaded(
          pieces(bytes, 1 << 16),
          const XZMultithreadOptions.converter(
              workers: 4, memoryBudget: 10 << 20));
      expect(many.error, isNull);
      expect(many.bytes, expected);
    });

    test('truncated input throws after sending complete blocks', () async {
      final built = buildArchive('blocks');
      final bytes = built.bytes;
      final blocks = built.blocks;
      final ends = {
        for (final block in blocks) block.uncompOffset,
        expected.length,
      };
      final indexStart = blocks.last.compOffset + blocks.last.totalSize;
      final cuts = <String, int>{
        'inside the first block': blocks[0].dataOffset + 100,
        'inside the third block': blocks[2].dataOffset + 100,
        'on the boundary of the fourth block': blocks[3].compOffset,
        'after the last block': indexStart,
        'inside the index': indexStart + 2,
        'inside the footer': bytes.length - 3,
      };
      for (final cut in cuts.entries) {
        final part = Uint8List.sublistView(bytes, 0, cut.value);
        final many = await threaded(pieces(part, 4096));
        expect(many.error, isA<ArchiveException>(), reason: cut.key);
        expect(isPrefix(many.bytes, expected), isTrue, reason: cut.key);
        expect(ends.contains(many.bytes.length), isTrue,
            reason: '${cut.key}: ${many.bytes.length} is not a block boundary');
      }
    });

    test('source error part way ends stream with same error', () async {
      final bytes = fixture('blocks');
      for (final at in [100, bytes.length ~/ 2, bytes.length - 20]) {
        final source = StreamController<List<int>>();
        final result = threaded(source.stream);
        source.add(Uint8List.sublistView(bytes, 0, at));
        source.addError(StateError('source failed'));
        final outcome = await result;
        expect(outcome.error, isA<StateError>(), reason: 'at $at');
        expect(isPrefix(outcome.bytes, expected), isTrue, reason: 'at $at');
        expect(source.hasListener, isFalse, reason: 'at $at');
        await source.close();
      }
    });

    test('paused listener stops decoding', () async {
      // The pump sent the next block whatever the consumer was doing, so a
      // paused stream decoded the archive into memory. Over 64 blocks of 4 MiB
      // of zeros RSS grew by 272 MB while the consumer held 64 KiB, the same
      // at one worker and at four and at a 1 MiB budget and at 1 GiB. The
      // blocks here are 64 MiB, so one sits in the worker and the rest wait
      const one = XZMultithreadOptions<Object?>.converter(workers: 1);
      var got = 0;
      final first = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = Stream<List<int>>.value(fixture('huge'))
          .transform(const XzCodec(multithread: one).decoder)
          .listen((piece) {
        got += piece.length;
        if (!first.isCompleted) {
          subscription.pause();
          first.complete();
        }
      });
      await first.future.timeout(const Duration(seconds: 30));
      // RSS is shared by all suites in runner process, so with `-j` above 1
      // other suites allocating in these 2 s fail this test: 645 MB was
      // measured at `-j 6`. Test passes alone and at `-j 1`
      // final held = ProcessInfo.currentRss;
      // await Future<void>.delayed(const Duration(seconds: 2));
      // final grew = ProcessInfo.currentRss - held;
      // await subscription.cancel();
      // expect(got, lessThan(1 << 20));
      // expect(grew, lessThan(192 << 20),
      //     reason: 'grew ${grew >> 20} MB while the consumer was paused');

      // RSS check fails under `-j`, so we count bytes sent in one event loop
      // turn after resume: 127 MiB with backpressure, 1471 MiB without it.
      // Check misses memory outside `ready`, which async* must drain at once
      await Future<void>.delayed(const Duration(seconds: 2));
      final paused = got;
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      final burst = got - paused;
      await subscription.cancel();
      expect(paused, lessThan(1 << 20));
      expect(burst, lessThan(256 << 20),
          reason: 'decoded ${burst >> 20} MiB while the consumer was paused');
    });

    test('cancel over silent input releases input', () async {
      // Nothing sent, and a header followed by part of a block: in both the
      // decoder is parked waiting on an input that neither sends nor closes
      for (final start in [<int>[], fixture('blocks').sublist(0, 1000)]) {
        final source = StreamController<List<int>>();
        final subscription = source.stream
            .transform(const XzCodec(multithread: options).decoder)
            .listen((_) {});
        if (start.isNotEmpty) {
          source.add(start);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await subscription.cancel().timeout(const Duration(seconds: 10));
        expect(source.hasListener, isFalse, reason: '${start.length} bytes');
        await source.close();
      }
    });

    test('complete archives are decoded before input closes', () async {
      for (final archive in [
        fixture('x86'),
        XZEncoder().encodeBytes(Uint8List.sublistView(expected, 0, 3000)),
        // One block whose header declares both lengths, so it goes to a worker
        // and no second block ever comes to start the pool
        fixture('whole'),
      ]) {
        final want = XZDecoder().decodeBytes(archive);
        final source = StreamController<List<int>>();
        var got = 0;
        final arrived = Completer<void>();
        final subscription = source.stream
            .transform(const XzCodec(multithread: options).decoder)
            .listen((piece) {
          got += piece.length;
          if (got >= want.length && !arrived.isCompleted) {
            arrived.complete();
          }
        });
        source.add(archive);
        await arrived.future.timeout(const Duration(seconds: 30));
        expect(got, want.length);
        await subscription.cancel().timeout(const Duration(seconds: 10));
        expect(source.hasListener, isFalse);
        await source.close();
      }
    });

    test('cancel of output cancels input', () async {
      final source = StreamController<List<int>>();
      final bytes = fixture('blocks');
      final first = Completer<void>();
      final subscription = source.stream
          .transform(const XzCodec(multithread: options).decoder)
          .listen((_) {
        if (!first.isCompleted) {
          first.complete();
        }
      });
      source.add(bytes);
      await first.future.timeout(const Duration(seconds: 30));
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('damaged archive gives same result as single-thread decoder',
        () async {
      final built = buildArchive('blocks');
      final pristine = built.bytes;
      final ends = {
        for (final block in built.blocks) block.uncompOffset,
        expected.length,
      };
      final blockHeader = (pristine[12] + 1) * 4;
      final offsets = [
        for (var i = 0; i < 12 + blockHeader; i++) i,
        for (var i = 12 + blockHeader; i < pristine.length; i += 4093) i,
        for (var i = pristine.length - 64; i < pristine.length; i++) i,
      ];
      for (final at in offsets) {
        final data = Uint8List.fromList(pristine)..[at] ^= 0xff;
        final one = await single(pieces(data, 1 << 16));
        final many = await threaded(pieces(data, 1 << 16));
        expect(many.error == null, one.error == null, reason: 'byte $at');
        if (one.error == null) {
          expect(many.bytes, one.bytes, reason: 'byte $at');
        } else {
          // Blocks off a worker come out whole and checked, so a failure
          // leaves true output ending where a block does
          expect(isPrefix(many.bytes, expected), isTrue, reason: 'byte $at');
          expect(ends.contains(many.bytes.length), isTrue,
              reason: 'byte $at: ${many.bytes.length} is not a block boundary');
        }
      }
    });

    test('startChunkedConversion with multithread throws ArgumentError', () {
      const codec = XzCodec(multithread: options);
      expect(() => codec.decoder.startChunkedConversion(BytesBuilderSink()),
          throwsArgumentError);
      expect(
          () => codec.decoder.convert(fixture('whole')), throwsArgumentError);
    });

    test('invalid workers or memoryBudget throws ArgumentError', () async {
      for (final bad in [
        const XZMultithreadOptions<Object?>.converter(workers: 0),
        const XZMultithreadOptions<Object?>.converter(memoryBudget: 0),
      ]) {
        final outcome = await threaded(pieces(fixture('whole'), 4096), bad);
        expect(outcome.error, isA<ArgumentError>());
      }
    });

    test('decodeBytes with multithread but no onDone throws ArgumentError', () {
      expect(
          () => XZDecoder().decodeBytes(fixture('whole'),
              multithread:
                  const XZMultithreadOptions<Uint8List>.converter(workers: 2)),
          throwsArgumentError);
    });
  });
}

class BytesBuilderSink implements Sink<List<int>> {
  final builder = BytesBuilder();

  @override
  void add(List<int> data) => builder.add(data);

  @override
  void close() {}
}

class _ReadFailure implements Exception {}

class _ThrowingInput extends InputMemoryStream {
  final Object failure;

  _ThrowingInput(super.bytes, this.failure);

  @override
  Uint8List toUint8List() => throw failure;
}

class _FailingInput extends InputMemoryStream {
  final Object failure;
  final int? seekTo;
  var armed = false;

  _FailingInput(super.bytes, this.failure, {this.seekTo});

  void _fail() {
    if (armed) {
      throw failure;
    }
  }

  void _failRead() {
    if (seekTo == null) {
      _fail();
    }
  }

  @override
  InputStream peekBytes(int count, {int offset = 0}) {
    _failRead();
    return super.peekBytes(count, offset: offset);
  }

  @override
  int readByte() {
    _failRead();
    return super.readByte();
  }

  @override
  InputStream readBytes(int count) {
    _failRead();
    return super.readBytes(count);
  }

  @override
  void setPosition(int v) {
    if (seekTo == null) {
      _fail();
    } else if (v == seekTo) {
      throw failure;
    }
    super.setPosition(v);
  }
}

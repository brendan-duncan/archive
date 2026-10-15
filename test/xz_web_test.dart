import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        ArchiveChecksumException,
        ArchiveException,
        InputMemoryStream,
        OutputMemoryStream,
        SinkOutputStream,
        XZCheck,
        XZDecoder,
        XZEncoder,
        XzCodec;
import 'package:archive/src/codecs/xz/xz_chunked.dart';
import 'package:archive/src/codecs/xz/xz_index.dart';
import 'package:test/test.dart';

class _Collect implements Sink<List<int>> {
  final bytes = BytesBuilder();

  @override
  void add(List<int> data) => bytes.add(data);

  @override
  void close() {}
}

// dart2js truncates every bitwise operator to 32 bits, so this file holds what
// the xz codec does above that. It reads no fixture and runs under `-p node`

void main() {
  group('xz web', () {
    test('index records size above 32 bits', () {
      // XzChunkedEncoder writes a stream of 4 GiB as one block, so the index
      // holds this record. `>>` gave 0x80 0x00, the encoding of zero
      expect(xzMultibyteInteger(4294967296),
          equals(Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x10])));
      expect(xzMultibyteInteger(4294967297),
          equals(Uint8List.fromList([0x81, 0x80, 0x80, 0x80, 0x10])));
      // 1 << 40 as a literal, since dart2js gives zero for a shift past 31
      expect(xzMultibyteInteger(1099511627776),
          equals(Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x80, 0x20])));
    });

    test('index records size within 32 bits', () {
      expect(xzMultibyteInteger(0), equals(Uint8List.fromList([0])));
      expect(xzMultibyteInteger(127), equals(Uint8List.fromList([0x7f])));
      expect(xzMultibyteInteger(128), equals(Uint8List.fromList([0x80, 0x01])));
      expect(xzMultibyteInteger(4294967295),
          equals(Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0x0f])));
    });

    test('CRC64 check is verified while streaming', () {
      final data = Uint8List.fromList(
          List<int>.generate(300000, (i) => (i * 31 + (i >> 9)) & 0xff));
      final archive = XZEncoder().encodeBytes(data, check: XZCheck.crc64);

      final good = _Collect();
      final output = SinkOutputStream(good);
      expect(
          XZDecoder().decodeStream(InputMemoryStream(archive), output,
              verify: true, throwOnError: true),
          isTrue);
      output.flush();
      expect(good.bytes.takeBytes(), data);

      final block = parseXZLayout(XZMemorySource(archive))!.blocks.last;
      final damaged = Uint8List.fromList(archive);
      damaged[block.compressedOffset + block.compressedLength - 1] ^= 1;
      expect(
          () => XZDecoder().decodeStream(
              InputMemoryStream(damaged), SinkOutputStream(_Collect()),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });

    test(
        'verify reports wrong header, index or footer CRC as checksum '
        'mismatch on every path', () async {
      final data = Uint8List.fromList(
          List<int>.generate(3000, (i) => (i * 31 + (i >> 9)) & 0xff));
      final archive = XZEncoder().encodeBytes(data);
      final end = archive.length;
      final blockHeaderSize = (archive[12] + 1) * 4;
      final crcOffsets = {
        'stream header': 8,
        'block header': 12 + blockHeaderSize - 4,
        'index': end - 16,
        'footer': end - 12,
      };
      for (final MapEntry(key: name, value: offset) in crcOffsets.entries) {
        final damaged = Uint8List.fromList(archive)..[offset] ^= 1;
        final checksum = throwsA(isA<ArchiveChecksumException>());
        expect(() => XZDecoder().decodeBytes(damaged, verify: true), checksum,
            reason: '$name, decodeBytes');
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(damaged), OutputMemoryStream(),
                verify: true),
            checksum,
            reason: '$name, decodeStream');
        expect(
            () => XZDecoder()
                .decodeLazy(InputMemoryStream(damaged), verify: true)
                .toUint8List(),
            checksum,
            reason: '$name, decodeLazy');
        expect(() => XzCodec().decoder.convert(damaged), checksum,
            reason: '$name, convert');
        await expectLater(
            Stream<List<int>>.fromIterable(
                    [damaged.sublist(0, 7), damaged.sublist(7)])
                .transform(XzCodec().decoder)
                .toList(),
            checksum,
            reason: '$name, transform');
        expect(
            () => XZDecoder()
                .decodeBytes(damaged, verify: false, throwOnError: true),
            throwsA(allOf(isA<ArchiveException>(),
                isNot(isA<ArchiveChecksumException>()))),
            reason: '$name, throwOnError without verify');
        expect(
            () => XzCodec(verify: false).decoder.convert(damaged),
            throwsA(allOf(isA<ArchiveException>(),
                isNot(isA<ArchiveChecksumException>()))),
            reason: '$name, convert without verify');
      }
    });
  });
}

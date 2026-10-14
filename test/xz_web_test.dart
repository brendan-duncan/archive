import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        ArchiveException,
        InputMemoryStream,
        SinkOutputStream,
        XZCheck,
        XZDecoder,
        XZEncoder;
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
  });
}

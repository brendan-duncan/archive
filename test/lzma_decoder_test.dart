import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

/// `lzma.compress(text, FORMAT_ALONE, lc 3, lp 0, pb 2)` of [_text] without
/// the 13-byte header, as NSIS stores a block of unknown size
const String _stream =
    '002714c535b94b2678ae91c86189ee89d78d00731ff35fde06bb6945b8dade41b4c5'
    '2cffff9ca40000';
final String _text = 'NSIS test block: ${'abcabcabd' * 20} end';

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (int i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  test('LZMA stream of unknown size stops at its end marker', () {
    final LzmaDecoder decoder = LzmaDecoder()
      ..reset(
          literalContextBits: 3,
          literalPositionBits: 0,
          positionBits: 2,
          resetDictionary: true);

    final Uint8List decoded =
        decoder.decode(InputMemoryStream(_bytes(_stream)), 1 << 16);

    expect(String.fromCharCodes(decoded), _text);
    expect(decoder.endMarkerSeen, isTrue);
  });

  test('LZMA stream cut before its end marker throws', () {
    final LzmaDecoder decoder = LzmaDecoder()
      ..reset(
          literalContextBits: 3,
          literalPositionBits: 0,
          positionBits: 2,
          resetDictionary: true);
    final Uint8List cut = _bytes(_stream.substring(0, _stream.length - 12));

    expect(() => decoder.decode(InputMemoryStream(cut), 1 << 16),
        throwsA(isA<ArchiveException>()));
    expect(decoder.endMarkerSeen, isFalse);
  });

  test('LZMA2 chunk with an end marker is rejected', () {
    // LZMA2 does not allow the marker, so a chunk that stops at one short of
    // its declared size is damaged, as liblzma reports it
    final xz = _xzWithOneChunk(_bytes(_stream), _text.length + 5);
    expect(
        () => XZDecoder().decodeBytes(xz, throwOnError: true),
        throwsA(isA<ArchiveException>().having(
            (e) => e.message, 'message', contains('LZMA data is corrupt'))));
  });
}

/// An xz stream with no check holding one LZMA2 chunk of [lzma], which was
/// encoded with lc 3, lp 0, pb 2, declared as [size] bytes in the chunk and
/// in the index
Uint8List _xzWithOneChunk(Uint8List lzma, int size) {
  List<int> vli(int value) => [
        for (; value >= 0x80; value >>= 7) (value & 0x7f) | 0x80,
        value,
      ];
  List<int> crc(List<int> bytes) {
    final c = getCrc32(bytes);
    return [c & 0xff, c >> 8 & 0xff, c >> 16 & 0xff, c >> 24 & 0xff];
  }

  List<int> padded(List<int> bytes) =>
      [...bytes, ...List.filled(-bytes.length % 4, 0)];

  const flags = [0, 0];
  // Size byte, no sizes and one filter: LZMA2 with a 4 KiB dictionary
  final blockHeader = padded([2, 0, 0x21, 1, 0]);
  final header = [...blockHeader, ...crc(blockHeader)];
  final chunk = [
    0xe0 | (size - 1) >> 16,
    (size - 1) >> 8 & 0xff,
    (size - 1) & 0xff,
    (lzma.length - 1) >> 8,
    (lzma.length - 1) & 0xff,
    3 + 2 * 45,
    ...lzma,
    0,
  ];
  final unpadded = header.length + chunk.length;
  final index = padded([0, ...vli(1), ...vli(unpadded), ...vli(size)]);
  final backward = (index.length + 4) ~/ 4 - 1;
  final footer = [
    backward & 0xff,
    backward >> 8 & 0xff,
    backward >> 16 & 0xff,
    backward >> 24,
    ...flags
  ];
  return Uint8List.fromList([
    0xfd, 0x37, 0x7a, 0x58, 0x5a, 0, ...flags, ...crc(flags), //
    ...header,
    ...padded(chunk),
    ...index, ...crc(index),
    ...crc(footer), ...footer, 0x59, 0x5a,
  ]);
}

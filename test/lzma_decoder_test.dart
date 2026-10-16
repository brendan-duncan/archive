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
}

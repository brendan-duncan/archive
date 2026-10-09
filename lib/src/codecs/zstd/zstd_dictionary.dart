import 'dart:typed_data';

import 'zstd_error.dart';
import 'zstd_fse.dart';
import 'zstd_huffman.dart';

const int _dictionaryMagic = 0xEC30A437;

/// A zstd dictionary, as described in RFC 8878 section 5.
///
/// A formatted dictionary, the kind `zstd --train` writes, starts with a
/// magic number and carries entropy tables and repeat offsets for frames to
/// start from. Anything else is taken whole as raw content.
class ZstdDictionary {
  /// The ID frames refer to this dictionary by, or zero for raw content.
  final int id;

  /// The bytes that precede each frame's content, for matches to refer back
  /// into.
  final Uint8List content;

  final ZstdHuffmanTable? huffman;
  final ZstdFseTable? llTable;
  final ZstdFseTable? ofTable;
  final ZstdFseTable? mlTable;

  /// The three repeat offsets frames start with.
  final List<int> repeatOffsets;

  ZstdDictionary._(this.id, this.content, this.huffman, this.llTable,
      this.ofTable, this.mlTable, this.repeatOffsets);

  /// Parses [bytes] as a dictionary.
  ///
  /// Throws a [ZstdFormatError] if they start with the dictionary magic
  /// number but are not a well formed dictionary.
  factory ZstdDictionary(List<int> bytes) {
    final d = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (d.length < 8 || _read32(d, 0) != _dictionaryMagic) {
      return ZstdDictionary._(0, d, null, null, null, null, const [1, 4, 8]);
    }
    final id = _read32(d, 4);
    var pos = 8;
    final huffman = ZstdHuffmanTable();
    pos = huffman.readDescription(d, pos, d.length);
    final of = ZstdFseTable(ZstdFseKind.offset, zstdOfMaxLog);
    pos = of.readDescription(d, pos, d.length);
    final ml = ZstdFseTable(ZstdFseKind.matchLength, zstdMlMaxLog);
    pos = ml.readDescription(d, pos, d.length);
    final ll = ZstdFseTable(ZstdFseKind.literalsLength, zstdLlMaxLog);
    pos = ll.readDescription(d, pos, d.length);
    if (pos + 12 > d.length) {
      throw ZstdFormatError('Truncated dictionary');
    }
    final reps = [_read32(d, pos), _read32(d, pos + 4), _read32(d, pos + 8)];
    pos += 12;
    final content = Uint8List.sublistView(d, pos);
    for (final r in reps) {
      if (r == 0 || r > content.length) {
        throw ZstdFormatError('Invalid dictionary repeat offset $r');
      }
    }
    return ZstdDictionary._(id, content, huffman, ll, of, ml, reps);
  }

  static int _read32(Uint8List d, int i) =>
      d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] * 0x1000000);
}

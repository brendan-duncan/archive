import 'dart:typed_data';

/// Build huffman table from length list.
class HuffmanTable {
  late Uint32List table;
  int maxCodeLength = 0;
  int minCodeLength = 0x7fffffff;

  HuffmanTable(List<int> lengths, {bool codeLengthCodes = false}) {
    final listSize = lengths.length;

    for (var i = 0; i < listSize; ++i) {
      if (lengths[i] > maxCodeLength) {
        maxCodeLength = lengths[i];
      }
      if (lengths[i] < minCodeLength) {
        minCodeLength = lengths[i];
      }
    }

    if (maxCodeLength > 15) {
      throw const FormatException('Invalid Huffman code length');
    }
    final counts = Uint16List(maxCodeLength + 1);
    for (final length in lengths) {
      if (length != 0) {
        counts[length]++;
      }
    }
    var available = 1;
    for (var bits = 1; bits <= maxCodeLength; bits++) {
      available = (available << 1) - counts[bits];
      if (available < 0) {
        throw const FormatException('Oversubscribed Huffman table');
      }
    }
    if (available > 0 && maxCodeLength > (codeLengthCodes ? 0 : 1)) {
      throw const FormatException('Incomplete Huffman table');
    }

    final size = 1 << maxCodeLength;
    table = Uint32List(size);

    for (var bitLength = 1, code = 0, skip = 2; bitLength <= maxCodeLength;) {
      for (var i = 0; i < listSize; ++i) {
        if (lengths[i] == bitLength) {
          var reversed = 0;
          var rTemp = code;
          for (var j = 0; j < bitLength; ++j) {
            reversed = (reversed << 1) | (rTemp & 1);
            rTemp >>= 1;
          }

          for (var j = reversed; j < size; j += skip) {
            table[j] = (bitLength << 16) | i;
          }

          ++code;
        }
      }

      ++bitLength;
      code <<= 1;
      skip <<= 1;
    }
  }
}

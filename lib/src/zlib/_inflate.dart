part of dart_archive;

class _Inflate {
  final _ByteBuffer input;
  final _ByteBuffer output;

  int bitsbuf = 0;
  int bitsbuflen = 0;

  _Inflate(this.input) :
    output = new _ByteBuffer();

  List<int> decompress() {
    output.clear();
    while (_parseBlock()) {
    }
    print('${input.length} -> ${output.length} : ${input.position}');
    return output.buffer;
  }

  /**
   * parse deflated block.
   */
  bool _parseBlock() {
    int hdr = _readBits(3);

    // BFINAL
    bool bfinal = false;
    if (hdr & 0x1 != 0) {
      bfinal = true;
    }

    // BTYPE
    hdr >>= 1;
    switch (hdr) {
      case _BLOCK_UNCOMPRESSED:
        _parseUncompressedBlock();
        break;
      case _BLOCK_FIXED_HUFFMAN:
        _parseFixedHuffmanBlock();
        break;
      case _BLOCK_DYNAMIC_HUFFMAN:
        _parseDynamicHuffmanBlock();
        break;
        // reserved or other
      default:
        throw new Exception('unknown BTYPE: $hdr');
    }

    return !bfinal;
  }

  /**
   * Read inflate bits
   */
  int _readBits(int length) {
    // not enough buffer
    while (bitsbuflen < length) {
      if (input.isEOF) {
        throw new Exception('input buffer is broken');
      }

      // input byte
      int octet = input.readByte();

      // concat octet
      bitsbuf |= octet << bitsbuflen;
      bitsbuflen += 8;
    }

    // output byte
    int octet = bitsbuf & /* MASK */ ((1 << length) - 1);
    bitsbuf >>= length;
    bitsbuflen -= length;

    return octet;
  }

  /**
   * Read huffman code using table
   */
  int _readCodeByTable(_HuffmanTable table) {
    List<int> codeTable = table.table;
    int maxCodeLength = table.maxCodeLength;

    // Not enough buffer
    while (bitsbuflen < maxCodeLength) {
      if (input.isEOF) {
        break;
      }

      int octet = input.readByte();

      bitsbuf |= octet << bitsbuflen;
      bitsbuflen += 8;
    }

    // read max length
    int codeWithLength = codeTable[bitsbuf & ((1 << maxCodeLength) - 1)];
    int codeLength = codeWithLength >> 16;

    bitsbuf >>= codeLength;
    bitsbuflen -= codeLength;

    return codeWithLength & 0xffff;
  }

  /**
   * Parse uncompressed block.
   */
  void _parseUncompressedBlock() {
    // skip buffered header bits
    bitsbuf = 0;
    bitsbuflen = 0;

    // len (1st)
    int len = input.readByte();
    // len (2nd)
    len |= input.readByte() << 8;

    // nlen (1st)
    int nlen = input.readByte();
    // nlen (2nd)
    nlen |= input.readByte() << 8;

    // check len & nlen
    if (len == ~nlen) {
      throw new Exception('invalid uncompressed block header: length verify');
    }

    // check size
    if (input.position + len > input.length) {
      throw new Exception('input buffer is broken');
    }

    output.writeBytes(input.readBytes(len));
  }

  void _parseFixedHuffmanBlock() {
    _decodeHuffman(_fixedLiteralLengthTable, _fixedDistanceTable);
  }

  void _parseDynamicHuffmanBlock() {
    // number of literal and length codes.
    int numLitLengthCodes = _readBits(5) + 257;
    // number of distance codes.
    int numDistanceCodes = _readBits(5) + 1;
    // number of code lengths.
    int numCodeLengths = _readBits(4) + 4;

    // decode code lengths
    Data.Uint8List codeLengths = new Data.Uint8List(_ORDER.length);
    for (int i = 0; i < numCodeLengths; ++i) {
      codeLengths[_ORDER[i]] = _readBits(3);
    }

    _HuffmanTable codeLengthsTable = new _HuffmanTable(codeLengths);

    // literal and length code
    Data.Uint8List litlenLengths = new Data.Uint8List(numLitLengthCodes);

    // distance code
    Data.Uint8List distLengths = new Data.Uint8List(numDistanceCodes);

    _decodeHuffman(
        new _HuffmanTable(_decode(numLitLengthCodes, codeLengthsTable, litlenLengths)),
        new _HuffmanTable(_decode(numDistanceCodes, codeLengthsTable, distLengths)));
  }

  void _decodeHuffman(_HuffmanTable litlen, _HuffmanTable dist) {
    int code;
    while ((code = _readCodeByTable(litlen)) != 256) {
      // literal
      if (code < 256) {
        output.writeByte(code);
        continue;
      }

      // length code
      int ti = code - 257;
      int codeLength = _LENGTH_CODE_TABLE[ti];
      if (_LENGTH_EXTRA_TABLE[ti] > 0) {
        codeLength += _readBits(_LENGTH_EXTRA_TABLE[ti]);
      }

      // dist code
      code = _readCodeByTable(dist);
      int codeDist = _DIST_CODE_TABLE[code];
      if (_DIST_EXTRA_TABLE[code] > 0) {
        codeDist += _readBits(_DIST_EXTRA_TABLE[code]);
      }

      // lz77 decode
      while ((codeLength--) > 0) {
        output.writeByte(output.peakAtOffset(-(codeDist - 1)));
      }
    }

    while (bitsbuflen >= 8) {
      bitsbuflen -= 8;
      input.position--;
    }
  }

  /**
   * decode function
   */
  List<int> _decode(int num, _HuffmanTable table, List<int> lengths) {
    int prev;

    for (int i = 0; i < num;) {
      int code = _readCodeByTable(table);
      switch (code) {
        case 16:
          int repeat = 3 + _readBits(2);
          while ((repeat--) > 0) {
            lengths[i++] = prev;
          }
          break;
        case 17:
          int repeat = 3 + _readBits(3);
          while ((repeat--) > 0) {
            lengths[i++] = 0;
          }
          prev = 0;
          break;
        case 18:
          int repeat = 11 + _readBits(7);
          while ((repeat--) > 0) {
            lengths[i++] = 0;
          }
          prev = 0;
          break;
        default:
          lengths[i++] = code;
          prev = code;
          break;
      }
    }

    return lengths;
  }

  // enum BlockType
  static const int _BLOCK_UNCOMPRESSED = 0;
  static const int _BLOCK_FIXED_HUFFMAN = 1;
  static const int _BLOCK_DYNAMIC_HUFFMAN = 2;

  /// Fixed huffman length code table
  static const List<int> _FIXED_LITERAL_LENGTHS = const [
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
      9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 7, 7, 7, 7, 7, 7, 7, 7,
      7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8];
  final _HuffmanTable _fixedLiteralLengthTable =
      new _HuffmanTable(_FIXED_LITERAL_LENGTHS);

  /// Fixed huffman distance code table
  static const List<int> _FIXED_DISTANCE_TABLE = const [
      5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
      5, 5, 5, 5, 5, 5 ];
  final _HuffmanTable _fixedDistanceTable =
      new _HuffmanTable(_FIXED_DISTANCE_TABLE);

  /// Buffer block size.
  static const int _RAW_INFLATE_BUFFER_SIZE = 0x8000;

  /// Max backward length for LZ77.
  static const int _MAX_BACKWARD_LENGTH = 32768;

  /// Max copy length for LZ77.
  static const int _MAX_COPY_LENGTH = 258;

  /// Huffman order
  static const List<int> _ORDER = const [
      16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 ];

  /// Huffman length code table.
  static const List<int> _LENGTH_CODE_TABLE = const [
      0x0003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000a, 0x000b,
      0x000d, 0x000f, 0x0011, 0x0013, 0x0017, 0x001b, 0x001f, 0x0023, 0x002b,
      0x0033, 0x003b, 0x0043, 0x0053, 0x0063, 0x0073, 0x0083, 0x00a3, 0x00c3,
      0x00e3, 0x0102, 0x0102, 0x0102 ];

  /// Huffman length extra-bits table.
  static const List<int> _LENGTH_EXTRA_TABLE = const [
      0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
      4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0 ];

  /// Huffman dist code table.
  static const List<int> _DIST_CODE_TABLE = const [
      0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0007, 0x0009, 0x000d, 0x0011,
      0x0019, 0x0021, 0x0031, 0x0041, 0x0061, 0x0081, 0x00c1, 0x0101, 0x0181,
      0x0201, 0x0301, 0x0401, 0x0601, 0x0801, 0x0c01, 0x1001, 0x1801, 0x2001,
      0x3001, 0x4001, 0x6001 ];

  /// Huffman dist extra-bits table.
  static const List<int> _DIST_EXTRA_TABLE = const [
      0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
      11, 11, 12, 12, 13, 13 ];
}

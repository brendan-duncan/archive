part of dart_archive;

/**
 * Decompress data with the zlib format decoder.
 */
class ZLibDecoder {
  List<int> decode(List<int> data) {

  }

  static const int MAX_BITS = 15;
  static const int D_CODES = 30;
  static const int BL_CODES = 19;

  static const LENGTH_CODES = 29;
  static const int LITERALS = 256;
  static const int L_CODES = (LITERALS + 1 + LENGTH_CODES);
  static const int HEAP_SIZE = (2 * L_CODES + 1);

  static const int END_BLOCK = 256;

  // Bit length codes must not exceed MAX_BL_BITS bits
  static const int MAX_BL_BITS = 7;

  // repeat previous bit length 3-6 times (2 bits of repeat count)
  static const int REP_3_6 = 16;

  // repeat a zero length 3-10 times (3 bits of repeat count)
  static const int REPZ_3_10 = 17;

  // repeat a zero length 11-138 times (7 bits of repeat count)
  static const int REPZ_11_138 = 18;

  // The lengths of the bit length codes are sent in order of decreasing
  // probability, to avoid transmitting the lengths for unused bit
  // length codes.

  static const int Buf_size = 8 * 2;

  // JZlib version : "1.0.2"
  static const int Z_DEFAULT_COMPRESSION = -1;

  // compression strategy
  static const int Z_FILTERED = 1;
  static const int Z_HUFFMAN_ONLY = 2;
  static const int Z_DEFAULT_STRATEGY = 0;

  static const int Z_NO_FLUSH = 0;
  static const int Z_PARTIAL_FLUSH = 1;
  static const int Z_FULL_FLUSH = 3;
  static const int Z_FINISH = 4;

  static const int Z_OK = 0;
  static const int Z_STREAM_END = 1;
  static const int Z_NEED_DICT = 2;
  static const int Z_STREAM_ERROR = -2;
  static const int Z_DATA_ERROR = -3;
  static const int Z_BUF_ERROR = -5;

  // Tree

  // see definition of array dist_code below
  static const List<int> _dist_code = const [
      0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
      9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
      11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
      12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13,
      13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
      13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14,
      14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
      14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
      14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
      14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
      15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
      15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
      15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 16, 17, 18, 18, 19, 19,
      20, 20, 20, 20, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23,
      23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
      24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
      26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
      26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27,
      27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
      27, 27, 27, 27, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
      28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
      28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
      28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 29,
      29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29,
      29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29,
      29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29, 29,
      29, 29, 29, 29, 29, 29, 29 ];

}

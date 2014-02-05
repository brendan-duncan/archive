part of archive;

class BitReader {
  InputStream input;

  BitReader(this.input);

  /**
   * Read a number of bits from the input stream.
   */
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    // TODO this can be optimized quite a bit.
    int value = 0;
    for (int i = 0; i < numBits; ++i) {
      if (_bitPos == 0) {
        _bitBuffer = input.readByte();
        _bitPos = 8;
      }
      int b = (_bitBuffer & _BIT_MASK[_bitPos]) >> (_bitPos - 1);
      value = (value << 1) | b;
      _bitPos--;
    }

    return value;
  }

  int _bitBuffer = 0;
  int _bitPos = 0;
  static const List<int> _BIT_MASK = const [0, 1, 2, 4, 8, 16, 32, 64, 128];
}

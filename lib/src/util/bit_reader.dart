part of archive;

class BitReader {
  InputStream input;

  BitReader(this.input);

  int readByte() => readBits(8);

  /**
   * Read a number of bits from the input stream.
   */
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    if (_bitPos == 0) {
      if (numBits == 8) {
        return input.readByte();
      }
      if (numBits == 16) {
        return (input.readByte() << 8) + input.readByte();
      }
      if (numBits == 24) {
        return (input.readByte() << 16) + (input.readByte() << 8) +
               input.readByte();
      }
      if (numBits == 32) {
        return (input.readByte() << 24) + (input.readByte() << 16) +
               (input.readByte() << 8) + input.readByte();
      }
    }

    int value = 0;
    /*if (numBits <= _bitPos) {
      int value = _bitBuffer & _BIT_MASK2[_bitPos];
      _bitPos -= numBits;
      return value;
    }

    if (_bitPos > 0) {
      value = _bitBuffer & _BIT_MASK2[_bitPos];
      numBits -= _bitPos;
      _bitBuffer = input.readByte();
      _bitPos = 8;
    }*/

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
  static const List<int> _BIT_MASK2 = const [0, 1, 3, 7, 15, 31, 63, 127, 255];
}

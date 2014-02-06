part of archive;

class BitWriter {
  OutputStream output;

  BitWriter(this.output);

  void writeByte(int byte) => writeBits(8, byte);

  void writeBytes(List<int> bytes) {
    for (int i = 0; i < bytes.length; ++i) {
      writeByte(bytes[i]);
    }
  }

  void writeUint16(int value) {
    writeByte((value >> 8) & 0xff);
    writeByte(value & 0xff);
  }

  void writeUint24(int value) {
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte(value & 0xff);
  }

  void writeUint32(int value) {
    writeByte((value >> 24) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte(value & 0xff);
  }

  void writeBits(int numBits, int value) {
    // TODO optimize
    if (_bitPos == 8 && numBits == 8) {
      output.writeByte(value & 0xff);
      return;
    }

    if (_bitPos == 8 && numBits == 16) {
      output.writeByte((value >> 8) & 0xff);
      output.writeByte(value & 0xff);
      return;
    }

    if (_bitPos == 8 && numBits == 24) {
      output.writeByte((value >> 16) & 0xff);
      output.writeByte((value >> 8) & 0xff);
      output.writeByte(value & 0xff);
      return;
    }

    if (_bitPos == 8 && numBits == 32) {
      output.writeByte((value >> 24) & 0xff);
      output.writeByte((value >> 16) & 0xff);
      output.writeByte((value >> 8) & 0xff);
      output.writeByte(value & 0xff);
      return;
    }

    while (numBits > 0) {
      numBits--;
      int b = (value >> numBits) & 0x1;
      _bitBuffer = (_bitBuffer << 1) | b;
      _bitPos--;
      if (_bitPos == 0) {
        output.writeByte(_bitBuffer);
        _bitPos = 8;
        _bitBuffer = 0;
      }
    }
  }

  /**
   * Write any remaining bits to the output.
   */
  void flush() {
    if (_bitPos != 8) {
      output.writeByte(_bitBuffer);
      _bitBuffer = 0;
      _bitPos = 8;
    }
  }

  int _bitBuffer = 0;
  int _bitPos = 8;
}

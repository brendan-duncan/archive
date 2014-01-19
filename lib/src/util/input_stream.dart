part of archive;

class InputStream {
  final List<int> buffer;
  int position = 0;
  final int byteOrder;

  /**
   * Create a InputStream for reading from a List<int>
   */
  InputStream(this.buffer, {this.byteOrder: LITTLE_ENDIAN}) :
    position = 0;

  /**
   * How many total bytes in the stream.
   */
  int get length => buffer.length;

  /**
   * How many bytes are left in the stream from the current position?
   */
  int get remainder => length - position;

  /**
   * Is the current position at the end of the stream?
   */
  bool get isEOS => position >= buffer.length;

  /**
   * Reset to the beginning of the stream.
   */
  void reset() {
    position = 0;
    bitBuffer = 0;
    bitBufferLen = 0;
  }

  /**
   * Return a InputStream to read a subset of this stream.  It does not
   * move the read position of this stream.
   * If [position] is not specified, the current read position is
   * used. If [length] is not specified, the remainder of this stream is used.
   */
  InputStream subset([int position, int length]) {
    if (position == null || position < 0) {
      position = this.position;
    }
    if (length == null || length < 0) {
      length = this.length - position;
    }

    int end = position + length;
    if (end > buffer.length) {
      end = buffer.length;
    }

    return new InputStream(buffer.sublist(position, end),
                           byteOrder: byteOrder);
  }

  /**
   * Read [count] bytes from an [offset] of the current read position, without
   * moving the read position.
   */
  List<int> peekBytes(int count, [int offset = 0]) {
    List<int> bytes = buffer.sublist(position + offset,
                                     position + offset + count);
    return bytes;
  }

  /**
   * Move the read position by [count] bytes.
   */
  void skip(int count) {
    position += count;
  }

  /**
   * Read a single byte.
   */
  int readByte() {
    bitBufferLen = 0;
    return buffer[position++];
  }

  /**
   * Read [count] bytes from the stream.
   */
  List<int> readBytes(int count) {
    bitBufferLen = 0;
    List<int> bytes = buffer.sublist(position, position + count);
    position += bytes.length;
    return bytes;
  }

  /**
   * Read a null-terminated string, or if [len] is provided, that number of
   * bytes returned as a string.
   */
  String readString([int len]) {
    if (len == null) {
      List<int> codes = [];
      while (!isEOS) {
        int c = readByte();
        if (c == 0) {
          return new String.fromCharCodes(codes);
        }
        codes.add(c);
      }
      throw new Exception('EOF reached without finding string terminator');
    }

    return new String.fromCharCodes(readBytes(len));
  }

  /**
   * Read a 16-bit word from the stream.
   */
  int readUint16() {
    bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  /**
   * Read a 24-bit word from the stream.
   */
  int readUint24() {
    bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  /**
   * Read a 32-bit word from the stream.
   */
  int readUint32() {
    bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    int b4 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /**
   * Read a 64-bit word form the stream.
   */
  int readUint64() {
    bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    int b4 = buffer[position++] & 0xff;
    int b5 = buffer[position++] & 0xff;
    int b6 = buffer[position++] & 0xff;
    int b7 = buffer[position++] & 0xff;
    int b8 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 56) | (b2 << 48) | (b3 << 40) | (b4 << 32) |
             (b5 << 24) | (b6 << 16) | (b7 << 8) | b8;
    }
    return (b8 << 56) | (b7 << 48) | (b6 << 40) | (b5 << 32) |
           (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /**
   * Reset the bit buffer.
   */
  void resetBits() {
    bitBuffer = 0;
    bitBufferLen = 0;
  }

  /**
   * Read a number of bits from the input stream.
   */
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    // Not enough bits left in the buffer.
    bool first = true;
    while (bitBufferLen < numBits) {
      if (isEOS) {
        throw new ArchiveException('Unexpected end of input stream.');
      }

      // read the next byte
      int octet = buffer[position++];

      // concat octet
      if (byteOrder == BIG_ENDIAN) {
        bitBuffer |= octet << bitBufferLen;
      } else {
        if (first) {
          bitBuffer = (bitBuffer & ((1 << bitBufferLen) - 1));
          first = false;
        }
        bitBuffer = (bitBuffer << 8) | octet;
      }

      bitBufferLen += 8;
    }

    if (byteOrder == BIG_ENDIAN) {
      int octet = bitBuffer & ((1 << numBits) - 1);
      bitBuffer >>= numBits;
      bitBufferLen -= numBits;
      return octet;
    }

    int mask = (1 << numBits) - 1;
    int octet = (bitBuffer >> (bitBufferLen - numBits)) & mask;
    bitBufferLen -= numBits;

    return octet;
  }

  int bitBuffer = 0;
  int bitBufferLen = 0;
}

part of archive;

class InputBuffer {
  final List<int> buffer;
  int position = 0;
  final int byteOrder;

  /**
   * Create a InputBuffer for reading from a List<int>
   */
  InputBuffer(this.buffer, {this.byteOrder: LITTLE_ENDIAN}) :
    position = 0;

  /**
   * How many bytes in the buffer.
   */
  int get length => buffer.length;

  /**
   * How many bytes are left in the buffer from the current position?
   */
  int get remainder => length - position;

  /**
   * Is the current position at the end of the buffer?
   */
  bool get isEOF => position >= buffer.length;

  /**
   * Return a InputBuffer to read a subset of this buffer.
   * If [position] is not specified, the current read position is
   * used. If [length] is not specified, the remainder of this buffer is used.
   */
  InputBuffer subset([int position, int length]) {
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

    return new InputBuffer(buffer.sublist(position, end),
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
    _bitBufferLen = 0;
    return buffer[position++];
  }

  /**
   * Read [count] bytes from the buffer.
   */
  List<int> readBytes(int count) {
    _bitBufferLen = 0;
    List<int> bytes = buffer.sublist(position, position + count);
    position += bytes.length;
    return bytes;
  }

  /**
   * Read a null-terminated string.
   */
  String readString([int len]) {
    if (len == null) {
      List<int> codes = [];
      while (!isEOF) {
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
   * Read a 16-bit word from the buffer.
   */
  int readUint16() {
    _bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  /**
   * Read a 24-bit word from the buffer.
   */
  int readUint24() {
    _bitBufferLen = 0;
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    if (byteOrder == BIG_ENDIAN) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  /**
   * Read a 32-bit word from the buffer.
   */
  int readUint32() {
    _bitBufferLen = 0;
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
   * Read a 64-bit word form the buffer.
   */
  int readUint64() {
    _bitBufferLen = 0;
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

  void resetBits() {
    _bitBuffer = 0;
    _bitBufferLen = 0;
  }

  /**
   * Read a number of bits from the input stream.
   */
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    if (numBits == 8) {
      return readByte();
    }

    if (numBits == 16) {
      return readUint16();
    }

    // not enough buffer
    if (_bitBufferLen < numBits) {
      if (isEOF) {
        throw new ArchiveException('Unexpected end of input buffer.');
      }

      // input byte
      int octet = buffer[position++];

      // concat octet
      _bitBuffer = octet << _bitBufferLen;
      _bitBufferLen += 8;
    }

    if (byteOrder == BIG_ENDIAN) {
      int octet = _bitBuffer & ((1 << length) - 1);
      _bitBuffer >>= length;
      _bitBufferLen -= length;

      return octet;
    }

    int mask = (numBits == 1) ? 1 :
               (numBits == 2) ? 3 :
               (numBits == 4) ? 0xf :
               (numBits == 8) ? 0xff :
               (numBits == 16) ? 0xffff : 0;

    int octet = (_bitBuffer >> (_bitBufferLen - numBits)) & mask;

    _bitBufferLen -= numBits;
    return octet;
  }

  int _bitBuffer = 0;
  int _bitBufferLen = 0;
}

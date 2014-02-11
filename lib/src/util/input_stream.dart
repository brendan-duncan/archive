part of archive;

/**
 * A buffer that can be read as a stream of bytes.
 */
class InputStream {
  final Uint8List buffer;
  int position;
  final int byteOrder;

  /**
   * Create a InputStream for reading from a List<int>
   */
  InputStream(buffer, {this.byteOrder: LITTLE_ENDIAN}) :
    this.buffer = (buffer is Uint8List) ?
                    buffer :
                  (buffer is ByteBuffer) ?
                    new Uint8List.view(buffer as ByteBuffer) :
                  (buffer is List<int>) ?
                    new Uint8List.fromList(buffer) :
                  throw new ArchiveException('Invalid buffer'),
    position = 0;

  /**
   * Create a copy of [other].
   */
  InputStream.from(InputStream other) :
    buffer = other.buffer,
    position = 0,
    byteOrder = other.byteOrder;

  /**
   * How many bytes are left in the stream.
   */
  int get length => buffer.length - position;

  /**
   * Is the current position at the end of the stream?
   */
  bool get isEOS => position >= buffer.length;

  /**
   * Reset to the beginning of the stream.
   */
  void reset() {
    position = 0;
  }

  /**
   * Access the buffer relative from the current position.
   */
  int operator[](int offset) => buffer[position + offset];

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
      length = buffer.length - position;
    }

    Uint8List sub = new Uint8List.view(buffer.buffer,
        buffer.offsetInBytes + position, length);

    return new InputStream(sub, byteOrder: byteOrder);
  }

  /**
   * Read [count] bytes from an [offset] of the current read position, without
   * moving the read position.
   */
  Uint8List peekBytes(int count, [int offset = 0]) {
    return new Uint8List.view(buffer.buffer,
                            buffer.offsetInBytes + position + offset, count);
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
    return buffer[position++];
  }

  /**
   * Read [count] bytes from the stream.
   */
  Uint8List readBytes(int count) {
    Uint8List bytes = new Uint8List.view(buffer.buffer,
                                               buffer.offsetInBytes + position,
                                               count);
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
      throw new ArchiveException('EOF reached without finding string terminator');
    }

    return new String.fromCharCodes(readBytes(len));
  }

  /**
   * Read a 16-bit word from the stream.
   */
  int readUint16() {
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
}

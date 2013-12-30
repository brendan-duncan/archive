part of dart_archive;

class _ByteBuffer {
  static const int LITTLE_ENDIAN = 0;
  static const int BIG_ENDIAN = 1;
  int byteOrder;
  List<int> buffer;
  int position = 0;

  /**
   * Create a byte buffer for writing.
   */
  _ByteBuffer() :
    buffer = new List<int>(),
    position = 0;

  /**
   * Create a ByteBuffer for reading from a List<int>
   */
  _ByteBuffer.read(this.buffer, {this.byteOrder: BIG_ENDIAN}) :
    position = 0;

  /**
   * Change the buffer that's being read from.
   */
  void resetTo(List<int> buffer) {
    this.buffer = buffer;
    position = 0;
  }

  /**
   * Clear the buffer.
   */
  void clear() =>
      resetTo(new List<int>());

  /**
   * How many bytes in the buffer.
   */
  int get length => buffer.length;

  /**
   * Is the current position at the end of the buffer?
   */
  bool get isEOF => position >= buffer.length;

  /**
   * Return a _ByteBuffer to read a subset of this buffer.
   * If [position] is not specified, the current read position is
   * used.  If [length] is not specified, the remainder of this buffer is used.
   */
  _ByteBuffer subset([int position, int length]) {
    if (position == null || position < 0) {
      position = this.position;
    }
    if (length == null || length < 0) {
      length = this.length - position;
    }

    return new _ByteBuffer.read(buffer.sublist(position, position + length),
                                byteOrder: this.byteOrder);
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
   * Read [count] bytes from the buffer.
   */
  List<int> readBytes(int count) {
    List<int> bytes = buffer.sublist(position, position + count);
    position += bytes.length;
    return bytes;
  }

  /**
   * Read a 16-bit word from the buffer.
   */
  int readUint16() {
    if (byteOrder == LITTLE_ENDIAN) {
      int value = (buffer[position + 1] << 8) | buffer[position];
      position += 2;
      return value;
    }
    int value = (buffer[position] << 8) | buffer[position + 1];
    position += 2;
    return value;
  }

  /**
   * Read a 32-bit word from the buffer.
   */
  int readUint32() {
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    int b4 = buffer[position++] & 0xff;
    if (byteOrder == LITTLE_ENDIAN) {
      return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
    }
    return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
  }

  /**
   * Look at a byte relative to the current position without moving the
   * read position.
   */
  int peakAtOffset(int offset) {
    int iOffset = position + offset;
    if (iOffset < 0 || iOffset >= buffer.length) {
      return 0;
    }
    return buffer[iOffset];
  }

  /**
   * Write a byte to the end of the buffer.
   */
  void writeByte(int value) {
    buffer.add(value & 0xff);
  }

  /**
   * Write a set of bytes to the end of the buffer.
   */
  void writeBytes(List<int> bytes) {
    buffer.addAll(bytes);
  }

  /**
   * Write a 16-bit word to the end of the buffer.
   */
  void writeUint16(int value) {
    if (byteOrder == LITTLE_ENDIAN) {
      writeByte((value) & 0xff);
      writeByte((value >> 8) & 0xff);
      return;
    }
    writeByte((value >> 8) & 0xff);
    writeByte((value) & 0xff);
  }

  /**
   * Write a 32-bit word to the end of the buffer.
   */
  void writeUint32(int value) {
    if (byteOrder == LITTLE_ENDIAN) {
      writeByte((value) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 24) & 0xff);
      return;
    }
    writeByte((value >> 24) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value) & 0xff);
  }
}

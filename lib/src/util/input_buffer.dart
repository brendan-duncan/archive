part of archive;

class InputBuffer {
  List<int> buffer;
  int position = 0;

  /**
   * Create a InputBuffer for reading from a List<int>
   */
  InputBuffer(this.buffer) :
    position = 0;

  /**
   * How many bytes in the buffer.
   */
  int get length => buffer.length;

  /**
   * Is the current position at the end of the buffer?
   */
  bool get isEOF => position >= buffer.length;

  /**
   * Return a InputBuffer to read a subset of this buffer.
   * If [position] is not specified, the current read position is
   * used.  If [length] is not specified, the remainder of this buffer is used.
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

    return new InputBuffer(buffer.sublist(position, end));
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
   * Read a null-terminated string.
   */
  String readString() {
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

  /**
   * Read a 16-bit word from the buffer.
   */
  int readUint16() {
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    return (b2 << 8) | b1;
  }

  /**
   * Read a 32-bit word from the buffer.
   */
  int readUint32() {
    int b1 = buffer[position++] & 0xff;
    int b2 = buffer[position++] & 0xff;
    int b3 = buffer[position++] & 0xff;
    int b4 = buffer[position++] & 0xff;
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /**
   * Read a 64-bit word form the buffer.
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
    return (b8 << 56) | (b7 << 48) | (b6 << 40) | (b5 << 32) |
           (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }
}

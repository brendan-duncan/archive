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

    return new InputBuffer(buffer.sublist(position, position + length));
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
}

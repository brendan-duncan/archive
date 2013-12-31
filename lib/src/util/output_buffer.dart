part of archive;

class OutputBuffer {
  static const int LITTLE_ENDIAN = 0;
  static const int BIG_ENDIAN = 1;
  int byteOrder;

  /**
   * Create a byte buffer for writing.
   */
  OutputBuffer() :
    _buffer = new List<int>();

  List<int> getBytes() => _buffer;

  /**
   * Change the buffer that's being read from.
   */
  void resetTo(List<int> buffer) {
    this._buffer = buffer;
  }

  /**
   * Clear the buffer.
   */
  void clear() =>
      resetTo(new List<int>());

  /**
   * How many bytes in the buffer.
   */
  int get length => _buffer.length;

  /**
   * Write a byte to the end of the buffer.
   */
  void writeByte(int value) {
    _buffer.add(value & 0xff);
  }

  /**
   * Write a set of bytes to the end of the buffer.
   */
  void writeBytes(List<int> bytes) {
    _buffer.addAll(bytes);
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

  /**
   * Return the subset of the buffer in the range [start:end].
   * If [start] or [end] are < 0 then it is relative to the end of the buffer.
   * If [end] is not specified (or null), then it is the end of the buffer.
   * This is equivalent to the python list range operator.
   */
  List<int> subset(int start, [int end]) {
    if (start < 0) {
      start = (_buffer.length) + start;
    }

    if (end == null) {
      end = _buffer.length;
    } else if (end < 0) {
      end = (_buffer.length) + end;
    }

    return _buffer.sublist(start, end);
  }

  /**
   * Look at a byte relative to the current position without moving the
   * read position.
   */
  int peakAtOffset(int offset) {
    int iOffset = (_buffer.length - 1) + offset;
    if (iOffset < 0 || iOffset >= _buffer.length) {
      return 0;
    }
    return _buffer[iOffset];
  }

  List<int> _buffer;
}

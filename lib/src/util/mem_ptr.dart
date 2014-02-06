part of archive;

/**
 * A helper class to work with List and TypedData in a way similar to pointers
 * in C.
 */
class MemPtr {
  var buffer;
  int offset;

  MemPtr(other, [this.offset = 0]) {
    if (other is MemPtr) {
      this.buffer = other.buffer;
      this.offset += other.offset;
    } else {
      this.buffer = other;
    }
  }

  int operator[](int index) => buffer[offset + index];

  operator[]=(int index, int value) => buffer[offset + index] = value;

  int get length => buffer.length - offset;

  void memcpy(int start, int length, other, [int offset = 0]) {
    if (other is MemPtr) {
      buffer.setRange(this.offset + start, this.offset + start + length,
                      other.buffer, other.offset + offset);
    } else {
      buffer.setRange(this.offset + start, this.offset + start + length,
                      other, offset);
    }
  }

  void memset(int start, int length, int value) {
    buffer.fillRange(offset + start, offset + start + length, value);
  }

  /**
   * This assumes buffer is a Typed
   */
  Uint8List toUint8List([int offset = 0]) {
    return new Uint8List.view(buffer.buffer,
        buffer.offsetInBytes + this.offset + offset);
  }

  /**
   * This assumes buffer is a Typed
   */
  Uint32List toUint32List([int offset = 0]) {
    return new Uint32List.view(buffer.buffer,
        buffer.offsetInBytes + this.offset + offset);
  }
}

import 'dart:math';
import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'byte_order.dart';

/// Buffered file reader reduces file system disk access by reading in
/// buffers of the file so that individual file reads
/// can be read from the cached buffer.
class FileBuffer {
  final ByteOrder byteOrder;
  final AbstractFileHandle file;
  Uint8List? _buffer;
  int _fileSize = 0;
  int _position = 0;
  // The size of the buffer, and how much of it holds bytes of the file: less
  // than the size after a read near the end of the file
  int _bufferSize = 0;
  int _bufferLength = 0;

  /// The buffer size should be at least 8 bytes, so reading a 64-bit value
  /// doesn't have to deal with buffer overflow.
  static const kMinBufferSize = 8;

  /// How much of the file is read at a time when it is being read through
  /// sequentially, which is what a decoder does. A read somewhere else in
  /// the file is a seek, after which only [kSeekReadSize] bytes are read,
  /// since a reader that jumps around, such as the zip decoder going from
  /// one local header to the next, would otherwise pull in this much at
  /// every stop.
  static const kDefaultBufferSize = 64 * 1024;

  /// How much is read after a seek. Sequential reads from there on fill the
  /// whole buffer.
  static const kSeekReadSize = 4 * 1024;

  /// Create a FileBuffer with the given [file].
  /// [byteOrder] determines if multi-byte values should be read in bigEndian
  /// or littleEndian order.
  /// [bufferSize] controls the size of the buffer to use for file IO caching.
  /// The larger the buffer, the less it will have to access the file system.
  FileBuffer(
    this.file, {
    this.byteOrder = ByteOrder.littleEndian,
    int bufferSize = kDefaultBufferSize,
  }) {
    if (!file.isOpen) {
      file.open();
    }
    _fileSize = file.length;
    // Prevent having a buffer smaller than the minimum buffer size
    _bufferSize = max(
      // If possible, avoid having a buffer bigger than the file itself
      min(bufferSize, _fileSize),
      kMinBufferSize,
    );
    _buffer = Uint8List(_bufferSize);
    _readBuffer(0);
  }

  FileBuffer.from(FileBuffer other, {int? bufferSize})
      : this.byteOrder = other.byteOrder,
        this.file = other.file {
    _bufferSize = max(bufferSize ?? other._bufferSize, kMinBufferSize);
    _position = other._position;
    _fileSize = other._fileSize;
    _buffer = Uint8List(_bufferSize);
    _readBuffer(_position);
  }

  /// The length of the file in bytes.
  int get length => _fileSize;

  /// True if the file is currently open.
  bool get isOpen => file.isOpen;

  /// Open the file synchronously for reading.
  bool open() => file.open();

  /// Get the file buffer, reloading it as necessary
  Uint8List get buffer {
    if (!file.isOpen) {
      file.open();
    }
    if (_buffer == null) {
      _buffer = Uint8List(_bufferSize);
      _readBuffer(_position);
    }
    return _buffer!;
  }

  /// Close the file asynchronously.
  Future<void> close() async {
    await file.close();
    _buffer = null;
  }

  /// Close the file synchronously.
  void closeSync() {
    file.closeSync();
    _buffer = null;
  }

  /// Reset the read position of the file back to 0.
  void reset() {
    _position = 0;
  }

  /// Read an 8-bit unsigned int at the given [position] within the file.
  ///
  /// The [fileSize] of the read methods is ignored: the buffer never reads
  /// past the end of the file, and a stream over part of the file keeps to
  /// its own bounds.
  int readUint8(int position, [@Deprecated('Ignored') int? fileSize]) {
    if (position >= _fileSize || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + _bufferLength)) {
      _readBuffer(position);
    }
    final p = position - _position;
    return _buffer![p];
  }

  /// Read a 16-bit unsigned int at the given [position] within the file.
  int readUint16(int position, [@Deprecated('Ignored') int? fileSize]) {
    if (position > (_fileSize - 2) || position < 0) {
      return 0;
    }
    if (position < _position || position + 2 > (_position + _bufferLength)) {
      _readBuffer(position, 2);
    }
    var p = position - _position;
    final b1 = _buffer![p++];
    final b2 = _buffer![p++];
    if (byteOrder == ByteOrder.bigEndian) {
      return (b1 << 8) | b2;
    }
    return (b2 << 8) | b1;
  }

  /// Read a 24-bit unsigned int at the given [position] within the file.
  int readUint24(int position, [@Deprecated('Ignored') int? fileSize]) {
    if (position > (_fileSize - 3) || position < 0) {
      return 0;
    }
    if (position < _position || position + 3 > (_position + _bufferLength)) {
      _readBuffer(position, 3);
    }
    var p = position - _position;
    final b1 = _buffer![p++];
    final b2 = _buffer![p++];
    final b3 = _buffer![p++];
    if (byteOrder == ByteOrder.bigEndian) {
      return b3 | (b2 << 8) | (b1 << 16);
    }
    return b1 | (b2 << 8) | (b3 << 16);
  }

  /// Read a 32-bit unsigned int at the given [position] within the file.
  int readUint32(int position, [@Deprecated('Ignored') int? fileSize]) {
    if (position > (_fileSize - 4) || position < 0) {
      return 0;
    }
    if (position < _position || position + 4 > (_position + _bufferLength)) {
      _readBuffer(position, 4);
    }
    var p = position - _position;
    final b1 = _buffer![p++];
    final b2 = _buffer![p++];
    final b3 = _buffer![p++];
    final b4 = _buffer![p++];
    if (byteOrder == ByteOrder.bigEndian) {
      return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    }
    return (b4 << 24) | (b3 << 16) | (b2 << 8) | b1;
  }

  /// Read a 64-bit unsigned int at the given [position] within the file.
  int readUint64(int position, [@Deprecated('Ignored') int? fileSize]) {
    if (position > (_fileSize - 8) || position < 0) {
      return 0;
    }
    if (position < _position || position + 8 > (_position + _bufferLength)) {
      _readBuffer(position, 8);
    }
    var p = position - _position;
    final b1 = _buffer![p++];
    final b2 = _buffer![p++];
    final b3 = _buffer![p++];
    final b4 = _buffer![p++];
    final b5 = _buffer![p++];
    final b6 = _buffer![p++];
    final b7 = _buffer![p++];
    final b8 = _buffer![p++];

    if (byteOrder == ByteOrder.bigEndian) {
      return (b1 << 56) |
          (b2 << 48) |
          (b3 << 40) |
          (b4 << 32) |
          (b5 << 24) |
          (b6 << 16) |
          (b7 << 8) |
          b8;
    }
    return (b8 << 56) |
        (b7 << 48) |
        (b6 << 40) |
        (b5 << 32) |
        (b4 << 24) |
        (b3 << 16) |
        (b2 << 8) |
        b1;
  }

  /// Read [count] bytes starting at the given [position] within the file.
  Uint8List readBytes(int position, int count,
      [@Deprecated('Ignored') int? fileSize]) {
    if (count > buffer.length) {
      // Clamp against the bytes left in the file rather than testing
      // `position + count >= _fileSize`, which overflows for a count near the
      // 64-bit maximum and would leave [count] huge, allocating an enormous
      // buffer. Written as a subtraction from the non-negative remainder.
      final available = position >= _fileSize ? 0 : _fileSize - position;
      if (count < 0 || count > available) {
        count = available;
      }
      final bytes = Uint8List(count);
      file.position = position;
      file.readInto(bytes);
      return bytes;
    }

    if (position < _position ||
        (position + count) > (_position + _bufferLength)) {
      _readBuffer(position, count);
    }

    final start = position - _position;
    final bytes = _buffer!.sublist(start, start + count);
    return bytes;
  }

  // Loads the buffer from [position], with at least [need] bytes of the file
  // where there are that many.
  void _readBuffer(int position, [int need = 0]) {
    if (!file.isOpen) {
      file.open();
    }
    if (_buffer == null) {
      _buffer = Uint8List(_bufferSize);
    }
    file.position = position;
    // Fill the buffer, not just the bytes the read asked for, so that every
    // later read within it is a hit. Unless this is a seek rather than the
    // continuation of a sequential read, when a smaller read is made in case
    // the next read is a seek too.
    final sequential =
        _bufferLength > 0 && position == _position + _bufferLength;
    final size = max(
        0,
        min(
            _fileSize - position,
            sequential
                ? _bufferSize
                : max(need, min(_bufferSize, kSeekReadSize))));
    _bufferLength = file.readInto(_buffer!, size);
    _position = position;
  }
}

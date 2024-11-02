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
  int _bufferSize = 0;

  /// The buffer size should be at least 8 bytes, so reading a 64-bit value
  /// doesn't have to deal with buffer overflow.
  static const kMinBufferSize = 8;
  static const kDefaultBufferSize = 1024;

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
    _readBuffer(0, _fileSize);
  }

  FileBuffer.from(FileBuffer other, {int? bufferSize})
      : this.byteOrder = other.byteOrder,
        this.file = other.file {
    _bufferSize = bufferSize ?? other._bufferSize;
    _position = other._position;
    _fileSize = other._fileSize;
    _buffer = Uint8List(_bufferSize);
    _readBuffer(_position, _bufferSize);
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
      _readBuffer(_position, _bufferSize);
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
  /// [fileSize] is used to ensure bytes aren't read past the end of
  /// an [InputFileStream].
  int readUint8(int position, [int? fileSize]) {
    if (position >= _fileSize || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + _bufferSize)) {
      _readBuffer(position, fileSize ?? _fileSize);
    }
    final p = position - _position;
    return _buffer![p];
  }

  /// Read a 16-bit unsigned int at the given [position] within the file.
  int readUint16(int position, [int? fileSize]) {
    if (position >= (_fileSize - 2) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 2))) {
      _readBuffer(position, fileSize ?? _fileSize);
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
  int readUint24(int position, [int? fileSize]) {
    if (position >= (_fileSize - 3) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 3))) {
      _readBuffer(position, fileSize ?? _fileSize);
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
  int readUint32(int position, [int? fileSize]) {
    if (position >= (_fileSize - 4) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 4))) {
      _readBuffer(position, fileSize ?? _fileSize);
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
  int readUint64(int position, [int? fileSize]) {
    if (position >= (_fileSize - 8) || position < 0) {
      return 0;
    }
    if (position < _position || position >= (_position + (_bufferSize - 8))) {
      _readBuffer(position, fileSize ?? _fileSize);
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
  Uint8List readBytes(int position, int count, [int? fileSize]) {
    if (count > buffer.length) {
      if (position + count >= _fileSize) {
        count = _fileSize - position;
      }
      final bytes = Uint8List(count);
      file.position = position;
      file.readInto(bytes);
      return bytes;
    }

    if (position < _position ||
        (position + count) >= (_position + _bufferSize)) {
      _readBuffer(position, fileSize ?? _fileSize);
    }

    final start = position - _position;
    final bytes = _buffer!.sublist(start, start + count);
    return bytes;
  }

  void _readBuffer(int position, int fileSize) {
    if (!file.isOpen) {
      file.open();
    }
    if (_buffer == null) {
      _buffer = Uint8List(_bufferSize);
    }
    file.position = position;
    final size = min(fileSize, _buffer!.length);
    _bufferSize = file.readInto(_buffer!, size);
    _position = position;
  }
}

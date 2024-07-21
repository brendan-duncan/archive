import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'byte_order.dart';
import 'file_buffer.dart';
import 'file_handle.dart';
import 'input_stream.dart';
import 'ram_file_handle.dart';

/// Stream in data from a file.
class InputFileStream extends InputStream {
  final FileBuffer _file;
  final int _fileOffset;
  late int _fileSize;
  int _position;

  /// Create an [InputFileStream] with the given [FileBuffer].
  /// [byteOrder] determines if multi-byte values are read in bigEndian or
  /// littleEndian order.
  InputFileStream.withFileBuffer(this._file,
      {super.byteOrder = ByteOrder.littleEndian})
      : _fileOffset = 0,
        _position = 0 {
    _fileSize = _file.length;
  }

  /// Create an [InputFileStream] with the given [AbstractFileHandle].
  /// [byteOrder] determines if multi-byte values are read in bigEndian or
  /// littleEndian order.
  InputFileStream.withFileHandle(AbstractFileHandle fh,
      {super.byteOrder = ByteOrder.littleEndian})
      : _file = FileBuffer(fh),
        _fileOffset = 0,
        _position = 0 {
    _fileSize = _file.length;
  }

  /// Create an [InputFileStream] with the given file system [path\.
  /// A file handle will be created to read from the file at that [path].
  /// [byteOrder] determines if multi-byte values are read in bigEndian or
  /// littleEndian order.
  /// [bufferSize] determines the size of the cache used by the created
  /// [FileBuffer].
  factory InputFileStream(
    String path, {
    ByteOrder byteOrder = ByteOrder.littleEndian,
    int bufferSize = FileBuffer.kDefaultBufferSize,
  }) {
    return InputFileStream.withFileBuffer(
        FileBuffer(FileHandle(path), bufferSize: bufferSize),
        byteOrder: byteOrder);
  }

  static Future<InputFileStream> asRamFile(
      Stream<Uint8List> stream, int fileLength,
      {ByteOrder byteOrder = ByteOrder.littleEndian}) async {
    return InputFileStream.withFileBuffer(
        FileBuffer(await RamFileHandle.fromStream(stream, fileLength)),
        byteOrder: byteOrder);
  }

  /// Create an [InputFileStream] from another [InputFileStream].
  /// If [position] is provided, it is the offset into [other] to start reading,
  /// relative to the current position of [other]. Otherwise the current
  /// position of [other] is used.
  /// If [length] is provided, it sets the length of this [InputFileStream],
  /// otherwise the remaining bytes in [other] is used.
  /// [bufferSize] determines the size of the cache used by the created
  /// [FileBuffer].
  InputFileStream.fromFileStream(InputFileStream other,
      {int? position, int? length, int? bufferSize})
      : _file = bufferSize != null
            ? new FileBuffer.from(other._file, bufferSize: bufferSize)
            : other._file,
        _fileOffset = other._fileOffset + (position ?? 0),
        _fileSize = length ?? other._fileSize,
        _position = 0,
        super(byteOrder: other.byteOrder);

  @override
  bool open() => _file.open();

  @override
  Future<void> close() async {
    await _file.close();
    _position = 0;
    _fileSize = 0;
  }

  @override
  void closeSync() {
    _file.closeSync();
    _position = 0;
    _fileSize = 0;
  }

  @override
  int get length => fileRemaining;

  @override
  int get position => _position;

  @override
  set position(int v) => setPosition(v);

  @override
  void setPosition(int v) {
    if (v < _position) {
      rewind(_position - v);
    } else if (v > _position) {
      skip(v - _position);
    }
  }

  @override
  bool get isEOS => _position >= _fileSize;

  int get fileRemaining => _fileSize - _position;

  @override
  void reset() {
    _position = 0;
  }

  @override
  void skip(int length) {
    _position += length;
  }

  @override
  void rewind([int length = 1]) {
    _position -= length;
    if (_position < 0) {
      _position = 0;
    }
  }

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) {
    return InputFileStream.fromFileStream(this,
        position: position, length: length, bufferSize: bufferSize);
  }

  @override
  int readByte() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint8(_fileOffset + _position, _fileSize);
    _position++;
    return b;
  }

  /// Read a 16-bit word from the stream.
  @override
  int readUint16() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint16(_fileOffset + _position, _fileSize);
    _position += 2;
    return b;
  }

  /// Read a 24-bit word from the stream.
  @override
  int readUint24() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint24(_fileOffset + _position, _fileSize);
    _position += 3;
    return b;
  }

  /// Read a 32-bit word from the stream.
  @override
  int readUint32() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint32(_fileOffset + _position, _fileSize);
    _position += 4;
    return b;
  }

  /// Read a 64-bit word form the stream.
  @override
  int readUint64() {
    if (isEOS) {
      return 0;
    }
    final b = _file.readUint64(_fileOffset + _position, _fileSize);
    _position += 8;
    return b;
  }

  @override
  InputStream readBytes(int count) {
    if (isEOS) {
      return InputFileStream.fromFileStream(this, length: 0);
    }
    if ((_position + count) > _fileSize) {
      count = _fileSize - _position;
    }
    final bytes = InputFileStream.fromFileStream(this,
        position: _position, length: count);
    _position += bytes.length;
    return bytes;
  }

  @override
  Uint8List toUint8List([Uint8List? bytes]) {
    if (isEOS) {
      return Uint8List(0);
    }
    return _file.readBytes(_fileOffset + position, fileRemaining, _fileSize);
  }

  FileBuffer get file => _file;
}

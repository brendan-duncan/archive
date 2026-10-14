import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'byte_order.dart';
import 'file_access.dart';
import 'file_handle.dart';
import 'input_decode_stream.dart';
import 'input_memory_stream.dart';
import 'input_stream.dart';
import 'output_stream.dart';
import 'ram_file_handle.dart';

class OutputFileStream extends OutputStream {
  int _length;
  final AbstractFileHandle _fileHandle;
  final Uint8List _buffer;
  int _bufferPosition;

  static const kDefaultBufferSize = 1024 * 1024; // 1MB

  OutputFileStream.withFileHandle(
    this._fileHandle, {
    super.byteOrder = ByteOrder.littleEndian,
    int? bufferSize,
  })  : _length = 0,
        _buffer = Uint8List(bufferSize == null
            ? kDefaultBufferSize
            : bufferSize < 1
                ? 1
                : bufferSize),
        _bufferPosition = 0;

  factory OutputFileStream(
    String path, {
    ByteOrder byteOrder = ByteOrder.littleEndian,
    int? bufferSize,
  }) {
    return OutputFileStream.withFileHandle(
      FileHandle(path, mode: FileAccess.write),
      byteOrder: byteOrder,
      bufferSize: bufferSize,
    );
  }

  factory OutputFileStream.toRamFile(
    RamFileHandle ramFileHandle, {
    ByteOrder byteOrder = ByteOrder.littleEndian,
    int? bufferSize,
  }) {
    return OutputFileStream.withFileHandle(
      ramFileHandle,
      byteOrder: byteOrder,
      bufferSize: bufferSize,
    );
  }

  @override
  bool get isOpen => _fileHandle.isOpen;

  @override
  int get length => _length;

  @override
  void flush() {
    if (_bufferPosition > 0) {
      if (isOpen) {
        _fileHandle.writeFromSync(_buffer, 0, _bufferPosition);
      }
      _bufferPosition = 0;
    }
  }

  @override
  Future<void> clear() async {
    await close();
  }

  @override
  Future<void> close() async {
    if (!isOpen) {
      return;
    }
    try {
      flush();
    } finally {
      await _fileHandle.close();
    }
  }

  @override
  void closeSync() {
    if (!isOpen) {
      return;
    }
    try {
      flush();
    } finally {
      _fileHandle.closeSync();
    }
  }

  /// Write a byte to the end of the buffer.
  @override
  void writeByte(int value) {
    _buffer[_bufferPosition++] = value;
    if (_bufferPosition == _buffer.length) {
      flush();
    }
    _length++;
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    final length = end - start;
    if (_bufferPosition + length >= _buffer.length) {
      flush();
    }
    if (_bufferPosition + length < _buffer.length) {
      _buffer.setRange(_bufferPosition, _bufferPosition + length, bytes, start);
      _bufferPosition += length;
      _length += length;
      return;
    }
    flush();
    // The whole list with a range, not a view of it: dart:io copies anything
    // that is not a `Uint8List` starting at zero
    _fileHandle.writeFromSync(bytes, start, end);
    _length += length;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    if (_bufferPosition + length >= _buffer.length) {
      flush();
    }

    if (_bufferPosition + length < _buffer.length) {
      _buffer.setRange(_bufferPosition, _bufferPosition + length, bytes);
      _bufferPosition += length;
      _length += length;
      return;
    }

    flush();
    if (bytes is Uint8List && length <= bytes.length) {
      _fileHandle.writeFromSync(Uint8List.view(bytes.buffer),
          bytes.offsetInBytes, bytes.offsetInBytes + length);
    } else {
      _fileHandle.writeFromSync(bytes, 0, length);
    }
    _length += length;
  }

  /// Writing sparse holes as zeros filled disk, 8 GiB from 2 KB tar. On disk
  /// we seek past them, so sparse file systems allocate no blocks
  void writeZeros(int count) {
    if (count <= 0) {
      return;
    }
    final handle = _fileHandle;
    if (handle is FileHandle && handle.isOpen) {
      flush();
      handle.position += count - 1;
      _length += count - 1;
      writeByte(0);
      return;
    }
    final zeros = Uint8List(count < 1 << 16 ? count : 1 << 16);
    while (count > 0) {
      final n = count < zeros.length ? count : zeros.length;
      writeBytes(zeros, length: n);
      count -= n;
    }
  }

  @override
  void writeStream(InputStream stream) {
    final held = stream.position;
    try {
      _writeStream(stream);
    } finally {
      stream.setPosition(held);
    }
  }

  void _writeStream(InputStream stream) {
    // InputDecodeStream.length decodes everything that is left into memory
    // before the first byte is written, so a lazy stream is read to its end
    if (stream is InputDecodeStream) {
      final chunk = Uint8List(16 * 1024);
      while (!stream.isEOS) {
        final got = stream.readInto(chunk, 0, chunk.length);
        if (got <= 0) {
          return;
        }
        writeBytes(chunk, length: got);
      }
      return;
    }
    var size = stream.length;
    const chunkSize = 1024 * 1024;
    // Fresh 1 MB array per chunk costs page faults on first write: reading
    // 1 GB file took 111 ms, against 45 ms with one reused buffer
    if (stream is! InputMemoryStream && size > 0) {
      final chunk = Uint8List(size < chunkSize ? size : chunkSize);
      while (size > 0) {
        final got = stream.readInto(
            chunk, 0, size < chunk.length ? size : chunk.length);
        if (got <= 0) {
          return;
        }
        writeBytes(chunk, length: got);
        size -= got;
      }
      return;
    }
    Uint8List? bytes;
    while (size > chunkSize) {
      bytes = stream.readBytes(chunkSize).toUint8List();
      writeBytes(bytes);
      size -= chunkSize;
    }
    if (size > 0) {
      bytes = stream.readBytes(size).toUint8List();
      writeBytes(bytes);
    }
  }

  /// Write a 16-bit word to the end of the buffer.
  @override
  void writeUint16(int value) {
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  /// Write a 32-bit word to the end of the buffer.
  @override
  void writeUint32(int value) {
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  /// Write a 64-bit word to the end of the buffer.
  @override
  void writeUint64(int value) {
    var topBit = 0x00;
    if (value & 0x8000000000000000 != 0) {
      topBit = 0x80;
      value ^= 0x8000000000000000;
    }
    if (byteOrder == ByteOrder.bigEndian) {
      writeByte(topBit | ((value >> 56) & 0xff));
      writeByte((value >> 48) & 0xff);
      writeByte((value >> 40) & 0xff);
      writeByte((value >> 32) & 0xff);
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
    writeByte((value >> 32) & 0xff);
    writeByte((value >> 40) & 0xff);
    writeByte((value >> 48) & 0xff);
    writeByte(topBit | ((value >> 56) & 0xff));
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final pos = _fileHandle.position + _bufferPosition;

    if (start < 0) {
      start = pos + start;
    }
    if (end != null && end < 0) {
      end = pos + end;
    }

    if (_bufferPosition > 0) {
      if (start >= _fileHandle.position) {
        if (end == null) {
          end = _fileHandle.position + _bufferPosition;
        }
        final length = end - start;
        final bufferStart = start - _fileHandle.position;
        final bufferEnd = bufferStart + length;
        final bytes = _buffer.sublist(bufferStart, bufferEnd);
        return bytes;
      }
      flush();
    }

    var length = 0;
    if (end == null) {
      end = pos;
    } else if (end < 0) {
      end = pos + end;
    }
    length = end - start;
    _fileHandle.position = start;
    final buffer = Uint8List(length);
    _fileHandle.readInto(buffer);
    _fileHandle.position = pos;
    return buffer;
  }
}

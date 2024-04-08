import 'dart:io';
import 'dart:typed_data';

import 'archive_exception.dart';
import 'byte_order.dart';
import 'input_stream.dart';
import 'output_stream.dart';
import 'input_stream_memory.dart';

class OutputStreamFile extends OutputStream {
  String path;
  int _length;
  RandomAccessFile? _fp;
  Uint8List? _buffer;
  int _bufferPosition = 0;
  final int _bufferSize;

  OutputStreamFile(this.path,
      {ByteOrder byteOrder = ByteOrder.littleEndian, int? bufferSize})
      : _length = 0,
        _bufferSize = bufferSize ?? 8192,
        super(byteOrder: byteOrder);

  @override
  int get length => _length;

  @override
  void open() {
    final file = File(path)..createSync(recursive: true);
    _fp = file.openSync(mode: FileMode.write);
  }

  @override
  void close() {
    if (_fp == null) {
      return;
    }
    flush();
    _fp?.closeSync();
    _fp = null;
  }

  @override
  bool get isOpen => _fp != null;

  @override
  void clear() {
    _length = 0;
    _fp?.setPositionSync(0);
  }

  @override
  void flush() {
    if (_bufferPosition > 0 && _buffer != null) {
      _fp?.writeFromSync(_buffer!, 0, _bufferPosition);
      _bufferPosition = 0;
    }
  }

  Uint8List _getBuffer() {
    if (_buffer != null) {
      return _buffer!;
    }
    _buffer = Uint8List(_bufferSize);
    return _buffer!;
  }

  /// Write a byte to the end of the buffer.
  @override
  void writeByte(int value) {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    b[_bufferPosition++] = value;
    if (_bufferPosition == b.length) {
      flush();
    }
    _length++;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  void writeBytes(Uint8List bytes, {int? length}) {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    length ??= bytes.length;
    if (_bufferPosition + length >= b.length) {
      flush();

      if (_bufferPosition + length < b.length) {
        for (var i = 0, j = _bufferPosition; i < length; ++i, ++j) {
          b[j] = bytes[i];
        }
        _bufferPosition += length;
        _length += length;
        return;
      }
    }

    flush();
    _fp!.writeFromSync(bytes, 0, length);
    _length += length;
  }

  @override
  void writeStream(InputStream stream) {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    if (stream is InputStreamMemory) {
      final len = stream.length;

      if (_bufferPosition + len >= b.length) {
        flush();

        if (_bufferPosition + len < b.length) {
          for (var i = 0, j = _bufferPosition, k = stream.position;
              i < len;
              ++i, ++j, ++k) {
            b[j] = stream.buffer[k];
          }
          _bufferPosition += len;
          _length += len;
          return;
        }
      }

      if (_bufferPosition > 0) {
        flush();
      }
      _fp!.writeFromSync(
          stream.buffer, stream.position, stream.position + stream.length);
      _length += stream.length;
    } else {
      final bytes = stream.toUint8List();
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, {int? end}) {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    if (_bufferPosition > 0) {
      flush();
    }
    final fp = _fp!;
    final pos = fp.positionSync();
    if (start < 0) {
      start = pos + start;
    }
    var length = 0;
    if (end == null) {
      end = pos;
    } else if (end < 0) {
      end = pos + end;
    }
    length = end - start;
    final buffer = Uint8List(length);
    fp
      ..setPositionSync(start)
      ..readIntoSync(buffer)
      ..setPositionSync(pos);
    return buffer;
  }
}

import 'dart:io';
import 'dart:typed_data';

import '../../archive.dart';

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
  Future<void> open() async {
    final file = await File(path).create(recursive: true);
    _fp = await file.open(mode: FileMode.write);
  }

  @override
  Future<void> close() async {
    if (_fp == null) {
      return;
    }
    await flush();
    await _fp?.close();
    _fp = null;
  }

  @override
  bool get isOpen => _fp != null;

  @override
  Future<void> clear() async {
    _length = 0;
    await _fp?.setPosition(0);
  }

  @override
  Future<void> flush() async {
    if (_bufferPosition > 0 && _buffer != null) {
      await _fp?.writeFrom(_buffer!, 0, _bufferPosition);
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
  Future<void> writeByte(int value) async {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    b[_bufferPosition++] = value;
    if (_bufferPosition == b.length) {
      await flush();
    }
    _length++;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  Future<void> writeBytes(Uint8List bytes, {int? length}) async {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    length ??= bytes.length;
    if (_bufferPosition + length >= b.length) {
      await flush();

      if (_bufferPosition + length < b.length) {
        for (var i = 0, j = _bufferPosition; i < length; ++i, ++j) {
          b[j] = bytes[i];
        }
        _bufferPosition += length;
        _length += length;
        return;
      }
    }

    await flush();
    await _fp!.writeFrom(bytes, 0, length);
    _length += length;
  }

  @override
  Future<void> writeStream(InputStream stream) async {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    final b = _getBuffer();
    if (stream is InputStreamMemory) {
      final len = stream.length;

      if (_bufferPosition + len >= b.length) {
        await flush();

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
        await flush();
      }
      await _fp!.writeFrom(
          stream.buffer, stream.position, stream.position + stream.length);
      _length += stream.length;
    } else {
      final bytes = await stream.toUint8List();
      await writeBytes(bytes);
    }
  }

  @override
  Future<Uint8List> subset(int start, {int? end}) async {
    if (!isOpen) {
      throw ArchiveException('OutputStreamFile is not open');
    }
    if (_bufferPosition > 0) {
      await flush();
    }
    final fp = _fp!;
    final pos = await fp.position();
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
    //final flen = fp.lengthSync();
    await fp.setPosition(start);
    final buffer = Uint8List(length);
    await fp.readInto(buffer);
    await fp.setPosition(pos);
    return buffer;
  }
}

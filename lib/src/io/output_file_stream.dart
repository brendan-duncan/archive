import 'dart:io';
import 'dart:typed_data';

import '../util/byte_order.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'input_file_stream.dart';

class OutputFileStream extends OutputStreamBase {
  String path;
  final int byteOrder;
  int _length;
  late RandomAccessFile _fp;

  OutputFileStream(this.path, {this.byteOrder = LITTLE_ENDIAN}) : _length = 0 {
    var file = File(path);
    file.createSync(recursive: true);
    _fp = file.openSync(mode: FileMode.write);
  }

  @override
  int get length => _length;

  void close() {
    _fp.closeSync();
  }

  /// Write a byte to the end of the buffer.
  @override
  void writeByte(int value) {
    _fp.writeByteSync(value);
    _length++;
  }

  /// Write a set of bytes to the end of the buffer.
  @override
  void writeBytes(dynamic bytes, [int? len]) {
    len ??= bytes.length as int;
    if (bytes is InputFileStream) {
      while (!bytes.isEOS) {
        final len = bytes.bufferRemaining;
        final data = bytes.readBytes(len);
        writeInputStream(data);
      }
    } else {
      _fp.writeFromSync(bytes as List<int>, 0, len);
    }
    _length += len;
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    if (stream is InputStream) {
      _fp.writeFromSync(stream.buffer, stream.offset, stream.length);
      _length += stream.length;
    } else {
      var bytes = stream.toUint8List();
      _fp.writeFromSync(bytes);
      _length += bytes.length;
    }
  }

  /// Write a 16-bit word to the end of the buffer.
  @override
  void writeUint16(int value) {
    if (byteOrder == BIG_ENDIAN) {
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
    if (byteOrder == BIG_ENDIAN) {
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

  List<int> subset(int start, [int? end]) {
    final pos = _fp.positionSync();
    if (start < 0) {
      start = pos + start;
    }
    var length = 0;
    if (end == null) {
      end = pos;
    } else if (end < 0) {
      end = pos + end;
    }
    length = (end - start);
    _fp.setPositionSync(start);
    final buffer = Uint8List(length);
    _fp.readIntoSync(buffer);
    _fp.setPositionSync(pos);
    return buffer;
  }
}

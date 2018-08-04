import 'dart:io';
import 'dart:typed_data';
import '../util/byte_order.dart';
import '../util/input_stream.dart';
import 'input_file_stream.dart';

class OutputFileStream {
  String path;
  final int byteOrder;
  int length;
  File _file;
  RandomAccessFile _fp;

  OutputFileStream(this.path, {this.byteOrder: LITTLE_ENDIAN})
    : length = 0 {
    _file = new File(path);
    _file.createSync(recursive: true);
    _fp = _file.openSync(mode: FileMode.write);
  }

  void close() {
    _fp.closeSync();
    _file = null;
  }

  /**
   * Write a byte to the end of the buffer.
   */
  void writeByte(int value) {
    _fp.writeByteSync(value);
    length++;
  }

  /**
   * Write a set of bytes to the end of the buffer.
   */
  void writeBytes(bytes, [int len]) {
    if (len == null) {
      len = bytes.length;
    }
    if (bytes is InputFileStream) {
      while (!bytes.isEOS) {
        int len = bytes.bufferRemaining;
        InputStream data = bytes.readBytes(len);
        writeInputStream(data);
      }
    } else {
      _fp.writeFromSync(bytes, 0, len);
    }
    length += len;
  }

  void writeInputStream(InputStream bytes) {
    _fp.writeFromSync(bytes.buffer, bytes.offset, bytes.length);
  }

  /**
   * Write a 16-bit word to the end of the buffer.
   */
  void writeUint16(int value) {
    if (byteOrder == BIG_ENDIAN) {
      writeByte((value >> 8) & 0xff);
      writeByte((value) & 0xff);
      return;
    }
    writeByte((value) & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  /**
   * Write a 32-bit word to the end of the buffer.
   */
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

  List<int> subset(int start, [int end]) {
    int pos = _fp.positionSync();
    if (start < 0) {
      start = pos + start;
    }
    int length = 0;
    if (end == null) {
      end = pos;
    } else if (end < 0) {
      end = pos + end;
    }
    length = (end - start);
    _fp.setPositionSync(start);
    Uint8List buffer = new Uint8List(length);
    _fp.readIntoSync(buffer);
    _fp.setPositionSync(pos);
    return buffer;
  }
}
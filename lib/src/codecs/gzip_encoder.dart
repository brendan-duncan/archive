import 'dart:typed_data';

import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zlib/deflate.dart';
import 'zlib/gzip_flag.dart';

class GZipEncoder {
  Uint8List encode(List<int> data,
      {int level = DeflateLevel.defaultCompression, OutputStream? output}) {
    return encodeStream(InputMemoryStream(data), level: level, output: output);
  }

  Uint8List encodeStream(InputStream data,
      {int level = DeflateLevel.defaultCompression, OutputStream? output}) {
    final dataLength = data.length;
    OutputStream outputStream = output ?? OutputMemoryStream();

    // The GZip format has the following structure:
    // Offset   Length   Contents
    // 0      2 bytes  magic header  0x1f, 0x8b (\037 \213)
    // 2      1 byte   compression method
    //                  0: store (copied)
    //                  1: compress
    //                  2: pack
    //                  3: lzh
    //                  4..7: reserved
    //                  8: deflate
    // 3      1 byte   flags
    //                  bit 0 set: file probably ascii text
    //                  bit 1 set: continuation of multi-part gzip file, part number present
    //                  bit 2 set: extra field present
    //                  bit 3 set: original file name present
    //                  bit 4 set: file comment present
    //                  bit 5 set: file is encrypted, encryption header present
    //                  bit 6,7:   reserved
    // 4      4 bytes  file modification time in Unix format
    // 8      1 byte   extra flags (depend on compression method)
    // 9      1 byte   OS type
    // [
    //        2 bytes  optional part number (second part=1)
    // ]?
    // [
    //        2 bytes  optional extra field length (e)
    //       (e)bytes  optional extra field
    // ]?
    // [
    //          bytes  optional original file name, zero terminated
    // ]?
    // [
    //          bytes  optional file comment, zero terminated
    // ]?
    // [
    //       12 bytes  optional encryption header
    // ]?
    //          bytes  compressed data
    //        4 bytes  crc32
    //        4 bytes  uncompressed input size modulo 2^32

    outputStream.writeUint16(GZipFlag.signature);
    outputStream.writeByte(GZipFlag.deflate);

    final flags = 0;
    final fileModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final extraFlags = 0;
    final osType = GZipFlag.osUnknown;

    outputStream.writeByte(flags);
    outputStream.writeUint32(fileModTime);
    outputStream.writeByte(extraFlags);
    outputStream.writeByte(osType);

    final deflate = Deflate.stream(data, level: level, output: outputStream);

    outputStream.writeUint32(deflate.crc32);

    outputStream.writeUint32(dataLength);

    outputStream.flush();

    return outputStream.getBytes();
  }
}

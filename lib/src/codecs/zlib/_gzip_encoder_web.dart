import 'dart:typed_data';

import '../../util/byte_order.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_encoder_base.dart';
import 'deflate.dart';
import 'gzip_flag.dart';

const platformGZipEncoder = _GZipEncoder();

class _GZipEncoder extends ZLibEncoderBase {
  const _GZipEncoder();

  @override
  Uint8List encodeBytes(List<int> bytes,
      {int? level, int? windowBits, bool raw = false}) {
    final output = OutputMemoryStream(byteOrder: ByteOrder.littleEndian);
    encodeStream(InputMemoryStream(bytes), output,
        level: level, windowBits: windowBits, raw: raw);
    return output.getBytes();
  }

  @override
  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false}) {
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

    if (raw) {
      Deflate.stream(input,
          level: level ?? 6, windowBits: windowBits ?? 15, output: output);
      output.flush();
      return;
    }

    final dataLength = input.length;

    output.writeUint16(GZipFlag.signature);
    output.writeByte(GZipFlag.deflate);

    final flags = 0;
    final fileModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final extraFlags = 0;
    final osType = GZipFlag.osUnknown;

    output.writeByte(flags);
    output.writeUint32(fileModTime);
    output.writeByte(extraFlags);
    output.writeByte(osType);

    final deflate = Deflate.stream(input,
        level: level ?? 6, windowBits: windowBits ?? 15, output: output);

    output.writeUint32(deflate.crc32);

    output.writeUint32(dataLength);

    output.flush();
  }
}

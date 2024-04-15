import 'dart:typed_data';

import '../util/adler32.dart';
import '../util/byte_order.dart';
import '../util/input_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/output_stream.dart';
import '../util/output_memory_stream.dart';
import 'zlib/deflate.dart';

class ZLibEncoder {
  static const int _deflate = 8;

  const ZLibEncoder();

  Uint8List encodeBytes(Uint8List bytes,
      {int level = DeflateLevel.defaultCompression}) {
    final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
    encodeStream(InputMemoryStream(bytes), output, level: level);
    return output.getBytes();
  }

  void encodeStream(InputStream input, OutputStream output,
      {int level = DeflateLevel.defaultCompression}) {
    output.byteOrder = ByteOrder.bigEndian;

    // Compression Method and Flags
    const cm = _deflate;
    const cinfo = 7; //2^(7+8) = 32768 window size

    const cmf = (cinfo << 4) | cm;
    output.writeByte(cmf);

    // 0x01, (00 0 00001) (FLG)
    // bits 0 to 4  FCHECK  (check bits for CMF and FLG)
    // bit  5       FDICT   (preset dictionary)
    // bits 6 to 7  FLEVEL  (compression level)
    // FCHECK is set such that (cmf * 256 + flag) must be a multiple of 31.
    const fdict = 0;
    const flevel = 0;
    var flag = ((flevel & 0x3) << 7) | ((fdict & 0x1) << 5);
    var fcheck = 0;
    const cmf256 = cmf * 256;
    while ((cmf256 + (flag | fcheck)) % 31 != 0) {
      fcheck++;
    }
    flag |= fcheck;
    output.writeByte(flag);

    final startPos = input.position;
    final adler32 = getAdler32Stream(input);

    input.setPosition(startPos);

    Deflate.stream(input, level: level, output: output);

    output
      ..writeUint32(adler32)
      ..flush();
  }
}

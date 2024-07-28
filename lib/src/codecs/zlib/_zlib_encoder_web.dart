import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/byte_order.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_encoder_base.dart';
import 'deflate.dart';

const platformZLibEncoder = _ZLibEncoder();

class _ZLibEncoder extends ZLibEncoderBase {
  static const _deflate = 8;

  const _ZLibEncoder();

  Uint8List encodeBytes(List<int> bytes,
      {int? level, int? windowBits, bool raw = false}) {
    final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
    encodeStream(InputMemoryStream(bytes), output,
        level: level, windowBits: windowBits, raw: raw);
    return output.getBytes();
  }

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false}) {
    output.byteOrder = ByteOrder.bigEndian;

    if (raw) {
      Deflate.stream(input,
          level: level ?? 6, windowBits: windowBits ?? 15, output: output);
      return;
    }

    final wb = (windowBits ?? 15).clamp(0, 15);

    // Compression Method and Flags
    const cm = _deflate;
    final cinfo = wb - 8; //2^(7+8) = 32768 window size

    final cmf = (cinfo << 4) | cm;
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
    final cmf256 = cmf * 256;
    while ((cmf256 + (flag | fcheck)) % 31 != 0) {
      fcheck++;
    }
    flag |= fcheck;
    output.writeByte(flag);

    final startPos = input.position;
    final adler32 = getAdler32Stream(input);

    input.setPosition(startPos);

    Deflate.stream(input,
        level: level ?? 6, windowBits: windowBits ?? 15, output: output);

    output
      ..writeUint32(adler32)
      ..flush();
  }
}

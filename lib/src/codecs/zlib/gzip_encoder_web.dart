import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_gzip_encoder_web.dart';
import '_zlib_encoder_base.dart';

class GZipEncoderWeb extends ZLibEncoderBase {
  const GZipEncoderWeb();

  @override
  Uint8List encodeBytes(List<int> data,
          {int? level, int? windowBits, bool raw = false}) =>
      platformGZipEncoder.encodeBytes(data,
          level: level ?? 6, windowBits: windowBits, raw: raw);

  @override
  void encodeStream(InputStream input, OutputStream output,
          {int? level, int? windowBits, bool raw = false}) =>
      platformGZipEncoder.encodeStream(input, output,
          level: level ?? 6, windowBits: windowBits, raw: raw);
}

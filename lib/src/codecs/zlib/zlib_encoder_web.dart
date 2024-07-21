import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_encoder_base.dart';
import '_zlib_encoder_web.dart';

class ZLibEncoderWeb extends ZLibEncoderBase {
  const ZLibEncoderWeb();

  @override
  Uint8List encodeBytes(List<int> data, {int? level, int? windowBits}) =>
      platformZLibEncoder.encodeBytes(data,
          level: level, windowBits: windowBits);

  @override
  void encodeStream(InputStream input, OutputStream output,
          {int? level, int? windowBits}) =>
      platformZLibEncoder.encodeStream(input, output,
          level: level, windowBits: windowBits);
}

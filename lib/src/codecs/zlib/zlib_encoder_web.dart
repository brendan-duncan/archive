import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_encoder_base.dart';
import '_zlib_encoder_web.dart';

class ZLibEncoderWeb extends ZLibEncoderBase {
  const ZLibEncoderWeb();

  @override
  Uint8List encodeBytes(List<int> data, {int level = 6}) =>
      platformZLibEncoder.encodeBytes(data, level: level);

  @override
  void encodeStream(InputStream input, OutputStream output, {int level = 6}) =>
      platformZLibEncoder.encodeStream(input, output, level: level);
}

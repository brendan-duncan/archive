import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_gzip_encoder_web.dart';
import '_zlib_encoder_base.dart';

class GZipEncoderWeb extends ZLibEncoderBase {
  const GZipEncoderWeb();

  @override
  Uint8List encodeBytes(List<int> data, {int level = 6}) =>
      platformGZipEncoder.encodeBytes(data, level: level);

  @override
  void encodeStream(InputStream input, OutputStream output, {int level = 6}) =>
      platformGZipEncoder.encodeStream(input, output, level: level);
}

import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_zlib_encoder.dart';

class ZLibEncoder {
  const ZLibEncoder();

  Uint8List encode(List<int> bytes, {int level = 6}) =>
      platformZLibEncoder.encode(bytes, level: level);

  void encodeStream(InputStream input, OutputStream output, {int level = 6}) =>
      platformZLibEncoder.encodeStream(input, output, level: level);
}

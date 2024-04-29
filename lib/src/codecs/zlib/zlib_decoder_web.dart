import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';
import '_zlib_decoder_web.dart';

class ZLibDecoderWeb extends ZLibDecoderBase {
  const ZLibDecoderWeb();

  @override
  Uint8List decodeBytes(List<int> data, {bool verify = false}) =>
      platformZLibDecoder.decodeBytes(data, verify: verify);

  @override
  void decodeStream(InputStream input, OutputStream output,
          {bool verify = false}) =>
      platformZLibDecoder.decodeStream(input, output, verify: verify);
}

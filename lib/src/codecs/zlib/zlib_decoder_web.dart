import 'dart:typed_data';

import '../../util/input_stream.dart';
import '_zlib_decoder_web.dart';
import 'zlib_decoder_base.dart';

class ZLibDecoderWeb extends ZLibDecoderBase {
  const ZLibDecoderWeb();

  @override
  Uint8List decode(List<int> data, {bool verify = false}) =>
      platformZLibDecoder.decode(data, verify: verify);

  @override
  Uint8List decodeStream(InputStream input, {bool verify = false}) =>
      platformZLibDecoder.decodeStream(input, verify: verify);
}

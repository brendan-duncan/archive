import 'dart:typed_data';
import 'zlib_decoder_base.dart';
import '_zlib_decoder_web.dart';
import '../../util/input_stream.dart';

class ZLibDecoderWeb extends ZLibDecoderBase {
  const ZLibDecoderWeb();

  @override
  Uint8List decodeBytes(Uint8List data, {bool verify = false}) =>
      platformZLibDecoder.decodeBytes(data, verify: verify);

  @override
  Uint8List decodeList(List<int> data, {bool verify = false}) =>
      platformZLibDecoder.decodeList(data, verify: verify);

  @override
  Uint8List decodeStream(InputStream input, {bool verify = false}) =>
      platformZLibDecoder.decodeStream(input, verify: verify);
}

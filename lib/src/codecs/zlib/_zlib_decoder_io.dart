import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import 'zlib_decoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Uint8List decode(List<int> data, {bool verify = false}) =>
      ZLibCodec().decoder.convert(data) as Uint8List;

  @override
  Uint8List decodeStream(InputStream input, {bool verify = false}) =>
      decode(input.toUint8List(), verify: verify);
}

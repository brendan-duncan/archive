import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Uint8List decode(List<int> data, {bool verify = false}) =>
      ZLibCodec().decode(data) as Uint8List;

  @override
  void decodeStream(InputStream input, OutputStream output,
      {bool verify = false}) {
    final decoded = decode(input.toUint8List(), verify: verify);
    output.writeBytes(decoded);
  }
}

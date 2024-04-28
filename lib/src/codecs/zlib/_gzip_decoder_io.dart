import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';

const platformGZipDecoder = _GZipDecoder();

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  const _GZipDecoder();

  @override
  Uint8List decode(List<int> data, {bool verify = false}) =>
      ZLibCodec(gzip: true).decoder.convert(data) as Uint8List;

  @override
  void decodeStream(InputStream input, OutputStream output,
      {bool verify = false}) {
    final bytes = decode(input.toUint8List(), verify: verify);
    output.writeBytes(bytes);
  }
}

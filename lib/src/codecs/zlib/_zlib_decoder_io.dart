import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import 'zlib_decoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Future<Uint8List> decodeBytes(Uint8List data, {bool verify = false}) async =>
      ZLibCodec().decoder.convert(data) as Uint8List;

  @override
  Future<Uint8List> decodeStream(InputStream input,
          {bool verify = false}) async =>
      decodeBytes(await input.toUint8List(), verify: verify);
}

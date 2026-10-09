import 'dart:io';
import 'dart:typed_data';

import '../../util/input_decode_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_native_chunk_decoder_io.dart';
import '_zlib_decoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
          {bool verify = false, bool raw = false}) =>
      ZLibCodec(raw: raw).decode(data) as Uint8List;

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false}) {
    final decoder = NativeChunkDecoder(input, gzip: false, raw: raw);
    while (decoder.decodeChunk(output)) {}
    return true;
  }

  @override
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      InputDecodeStream(NativeChunkDecoder(input, gzip: false, raw: raw));
}

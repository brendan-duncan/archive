import 'dart:io';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_native_chunk_decoder_io.dart';
import '_zlib_decoder_base.dart';

const platformGZipDecoder = _GZipDecoder();

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  const _GZipDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
          {bool verify = false, bool raw = false}) =>
      GZipCodec().decode(data) as Uint8List;

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false}) {
    final decoder = NativeChunkDecoder(input, gzip: true);
    try {
      while (decoder.decodeChunk(output)) {}
    } on ArchiveException {
      return false;
    }
    return true;
  }

  @override
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      InputDecodeStream(NativeChunkDecoder(input, gzip: true));
}

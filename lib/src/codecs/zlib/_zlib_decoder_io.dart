import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_output_stream_sink.dart';
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
    final inSink = ZLibCodec(raw: raw)
        .decoder
        .startChunkedConversion(OutputStreamSink(output));

    while (!input.isEOS) {
      final chunkSize = min(zlibChunkSize, input.length);
      final chunk = input.readBytes(chunkSize).toUint8List();
      inSink.add(chunk);
    }
    inSink.close();

    return true;
  }
}

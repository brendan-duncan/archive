import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_output_stream_sink.dart';
import '_zlib_encoder_base.dart';

const platformZLibEncoder = _ZLibEncoder();

class _ZLibEncoder extends ZLibEncoderBase {
  const _ZLibEncoder();

  Uint8List encodeBytes(List<int> bytes,
          {int? level, int? windowBits, bool raw = false}) =>
      ZLibCodec(level: level ?? 6, windowBits: windowBits ?? 15, raw: raw)
          .encode(bytes) as Uint8List;

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false}) {
    final inSink =
        ZLibCodec(level: level ?? 6, windowBits: windowBits ?? 15, raw: raw)
            .encoder
            .startChunkedConversion(OutputStreamSink(output));

    while (!input.isEOS) {
      final chunkSize = min(zlibChunkSize, input.length);
      final chunk = input.readBytes(chunkSize).toUint8List();
      inSink.add(chunk);
    }
    inSink.close();
  }
}

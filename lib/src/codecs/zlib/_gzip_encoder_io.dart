import 'dart:io';
import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_output_stream_sink.dart';
import '_zlib_encoder_base.dart';

const platformGZipEncoder = _GZipEncoder();

class _GZipEncoder extends ZLibEncoderBase {
  const _GZipEncoder();

  @override
  Uint8List encodeBytes(List<int> bytes,
          {int? level, int? windowBits, bool raw = false}) =>
      GZipCodec(level: level ?? 6, windowBits: windowBits ?? 15, raw: raw)
          .encode(bytes) as Uint8List;

  @override
  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false}) {
    final outSink = ZLibOutputSink(output);

    final inSink =
        GZipCodec(level: level ?? 6, windowBits: windowBits ?? 15, raw: raw)
            .encoder
            .startChunkedConversion(outSink);

    // A lazy source's length would decode its entire remainder into RAM.
    // Reuse one scratch buffer for both memory-backed and file-backed input.
    // The native chunked codec consumes add() synchronously.
    final scratch = Uint8List(zlibChunkSize);
    while (!input.isEOS) {
      final got = input.readInto(scratch, 0, scratch.length);
      if (got <= 0) {
        break;
      }
      inSink.add(Uint8List.sublistView(scratch, 0, got));
    }
    inSink.close();
  }
}

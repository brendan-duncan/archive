import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

const platformGZipEncoder = _GZipEncoder();

class _GZipEncoder {
  const _GZipEncoder();

  Uint8List encodeBytes(List<int> bytes, {int? level, int? windowBits}) =>
      GZipCodec(level: level ?? 6, windowBits: windowBits ?? 15).encode(bytes)
          as Uint8List;

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits}) {
    final outSink = ChunkedConversionSink<List<int>>.withCallback((chunks) {
      for (final chunk in chunks) {
        output.writeBytes(chunk);
      }
      output.flush();
    });

    final inSink = GZipCodec(level: level ?? 6, windowBits: windowBits ?? 15)
        .encoder
        .startChunkedConversion(outSink);

    while (!input.isEOS) {
      final chunkSize = min(1024, input.length);
      final chunk = input.readBytes(chunkSize).toUint8List();
      inSink.add(chunk);
    }
    inSink.close();
  }
}

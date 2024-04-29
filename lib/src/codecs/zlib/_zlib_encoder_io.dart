import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

const platformZLibEncoder = _ZLibEncoder();

class _ZLibEncoder {
  const _ZLibEncoder();

  Uint8List encodeBytes(List<int> bytes, {int level = 6}) =>
      ZLibCodec(level: level).encode(bytes) as Uint8List;

  void encodeStream(InputStream input, OutputStream output, {int level = 6}) {
    final outSink = ChunkedConversionSink<List<int>>.withCallback((chunks) {
      for (final chunk in chunks) {
        output.writeBytes(chunk);
      }
    });

    final inSink = ZLibCodec().encoder.startChunkedConversion(outSink);

    while (!input.isEOS) {
      final chunkSize = min(1024, input.length);
      final chunk = input.readBytes(chunkSize).toUint8List();
      inSink.add(chunk);
    }
    inSink.close();
  }
}

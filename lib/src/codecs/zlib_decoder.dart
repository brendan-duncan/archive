import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_zlib_decoder.dart';

/// Decompress data with the zlib format decoder.
class ZLibDecoder {
  const ZLibDecoder();

  Uint8List decodeBytes(List<int> bytes, {bool verify = false}) =>
      platformZLibDecoder.decodeBytes(bytes, verify: verify);

  void decodeStream(InputStream input, OutputStream output,
          {bool verify = false}) =>
      platformZLibDecoder.decodeStream(input, output, verify: verify);
}

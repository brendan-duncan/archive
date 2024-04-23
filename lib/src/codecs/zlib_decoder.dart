import 'dart:typed_data';

import '../util/input_stream.dart';
import 'zlib/zlib_decoder.dart';

/// Decompress data with the zlib format decoder.
class ZLibDecoder {
  const ZLibDecoder();

  Uint8List decode(Uint8List data, {bool verify = false}) =>
      platformZLibDecoder.decodeBytes(data, verify: verify);

  Uint8List decodeStream(InputStream input, {bool verify = false}) =>
      platformZLibDecoder.decodeStream(input, verify: verify);
}

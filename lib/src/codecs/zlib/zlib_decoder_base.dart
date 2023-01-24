import 'dart:typed_data';

import '../../util/input_stream.dart';

/// Decompress data with the zlib format decoder.
abstract class ZLibDecoderBase {
  const ZLibDecoderBase();

  Uint8List decodeBytes(Uint8List data, {bool verify = false});

  Uint8List decodeStream(InputStream input, {bool verify = false});
}

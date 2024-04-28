import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_gzip_decoder.dart';

/// Decompress data with the gzip format decoder.
class GZipDecoder {
  Uint8List decode(List<int> bytes, {bool verify = false}) =>
      platformGZipDecoder.decode(bytes, verify: verify);

  void decodeStream(InputStream input, OutputStream output,
          {bool verify = false}) =>
      platformGZipDecoder.decodeStream(input, output, verify: verify);
}

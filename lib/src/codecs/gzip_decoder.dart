import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_gzip_decoder.dart';

/// Decompress data with the gzip format decoder.
/// The actual decoder used will depend on the platform the code is run on.
/// In a 'dart:io' based platform, like Flutter, the native GZipCodec will
/// be used to improve performance. On web platforms, a Dart implementation
/// of ZLib will be used, via the [Inflate] class.
/// If you want to force the use of the Dart implementation, you can use the
/// [GZipDecoderWeb] class.
class GZipDecoder {
  const GZipDecoder();

  /// Decompress the given [bytes] with the GZip format.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  Uint8List decodeBytes(List<int> bytes, {bool verify = false}) =>
      platformGZipDecoder.decodeBytes(bytes, verify: verify);

  /// Decompress the given [input] with the GZip format, writing the
  /// decompressed data to the [output] stream.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false}) =>
      platformGZipDecoder.decodeStream(input, output, verify: verify);
}

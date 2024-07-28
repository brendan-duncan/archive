import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_zlib_decoder.dart';

/// Decompress data with the zlib format decoder.
/// The actual decoder used will depend on the platform the code is run on.
/// In a 'dart:io' based platform, like Flutter, the native ZLibCodec will
/// be used to improve performance. On web platforms, a Dart implementation
/// of ZLib will be used, via the [Inflate] class.
/// If you want to force the use of the Dart implementation, you can use the
/// [ZLibDecoderWeb] class.
class ZLibDecoder {
  const ZLibDecoder();

  /// Decompress the given [bytes] with the ZLib format.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  /// If [raw] is true, the input will be considered deflate compressed data
  /// without a zlib header.
  Uint8List decodeBytes(List<int> bytes,
          {bool verify = false, bool raw = false}) =>
      platformZLibDecoder.decodeBytes(bytes, verify: verify, raw: raw);

  /// Decompress the given [input] with the ZLib format, writing the
  /// decompressed data to the [output] stream.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  /// If [raw] is true, the input will be considered deflate compressed data
  /// without a zlib header.
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false, bool raw = false}) =>
      platformZLibDecoder.decodeStream(input, output, verify: verify, raw: raw);
}

import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_gzip_encoder.dart';

/// Compress data with the GZip format encoder.
/// The actual encoder used will depend on the platform the code is run on.
/// In a 'dart:io' based platform, like Flutter, the native GZipCodec will
/// be used to improve performance. On web platforms, a Dart implementation
/// of ZLib will be used, via the [Deflate] class.
/// If you want to force the use of the Dart implementation, you can use the
/// [GZipEncoderWeb] class.
class GZipEncoder {
  const GZipEncoder();

  /// Compress the given [bytes] with the GZip format.
  /// [level] will set the compression level to use, between 0 and 9.
  Uint8List encodeBytes(List<int> bytes, {int? level}) =>
      platformGZipEncoder.encodeBytes(bytes, level: level);

  /// Alias for [encodeBytes], kept for backwards compatibility.
  List<int> encode(List<int> bytes, {int? level}) =>
      encodeBytes(bytes, level: level);

  /// Compress the given [input] stream with the GZip format.
  /// [level] will set the compression level to use, between 0 and 9.
  void encodeStream(InputStream input, OutputStream output, {int? level}) =>
      platformGZipEncoder.encodeStream(input, output, level: level);
}

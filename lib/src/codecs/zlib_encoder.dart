import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_zlib_encoder.dart';

/// Compress data with the zlib format encoder.
/// The actual encoder used will depend on the platform the code is run on.
/// In a 'dart:io' based platform, like Flutter, the native ZLibCodec will
/// be used to improve performance. On web platforms, a Dart implementation
/// of ZLib will be used, via the [Deflate] class.
/// If you want to force the use of the Dart implementation, you can use the
/// [ZLibEncoderWeb] class.
class ZLibEncoder {
  const ZLibEncoder();

  static const maxWindowBits = 15;

  /// Compress the given [bytes] with the ZLib format.
  /// [level] will set the compression level to use, between 0 and 9, 6 is the
  /// default.
  Uint8List encodeBytes(List<int> bytes,
          {int? level, int windowBits = maxWindowBits}) =>
      platformZLibEncoder.encodeBytes(bytes, level: level);

  /// Alias for [encodeBytes], kept for backwards compatibility.
  List<int> encode(List<int> bytes,
          {int? level, int windowBits = maxWindowBits}) =>
      encodeBytes(bytes, level: level, windowBits: windowBits);

  /// Compress the given [input] stream with the ZLib format.
  /// [level] will set the compression level to use, between 0 and 9, 6 is the
  /// default.
  void encodeStream(InputStream input, OutputStream output,
          {int? level, int windowBits = maxWindowBits}) =>
      platformZLibEncoder.encodeStream(input, output,
          level: level, windowBits: windowBits);
}

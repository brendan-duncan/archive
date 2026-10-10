import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
import '../util/input_decode_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
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
  ///
  /// With [maxOutputSize], an [ArchiveException] is thrown as soon as the
  /// decoded data would pass that many bytes, rather than decoding a small
  /// input that expands without limit.
  Uint8List decodeBytes(List<int> bytes,
      {bool verify = false, bool raw = false, int? maxOutputSize}) {
    if (maxOutputSize == null) {
      return platformZLibDecoder.decodeBytes(bytes, verify: verify, raw: raw);
    }
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(bytes), output,
        verify: verify, raw: raw, maxOutputSize: maxOutputSize);
    return output.getBytes();
  }

  /// Decompress the given [input] with the ZLib format, writing the
  /// decompressed data to the [output] stream.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  /// If [raw] is true, the input will be considered deflate compressed data
  /// without a zlib header.
  ///
  /// With [maxOutputSize], an [ArchiveException] is thrown as soon as more
  /// than that many bytes would be written to [output].
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false, bool raw = false, int? maxOutputSize}) =>
      decodeLimited(
          output,
          maxOutputSize,
          (output) => platformZLibDecoder.decodeStream(input, output,
              verify: verify, raw: raw));

  /// Returns an [InputStream] that decompresses [input] as it is read.
  ///
  /// Nothing is decoded until the returned stream is read, and only a window
  /// of the decoded data is held in memory. The stream is read forwards: see
  /// [InputDecodeStream] for what that means. A malformed or truncated input
  /// throws an [ArchiveException] from the read that runs into it.
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      platformZLibDecoder.decodeLazy(input, verify: verify, raw: raw);
}

import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
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
  ///
  /// If [raw] is true, the input will be considered deflate compressed data
  /// without a zlib header.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only `verify` finds a cut stream: `ArchiveChecksumException`.
  /// Over 4 KB of bytes after the stream also read as a wrong checksum there.
  /// Neither flag finds a cut [raw] stream there: it has no checksum.
  ///
  /// {@macro archive.max_output_size.bytes}
  Uint8List decodeBytes(List<int> bytes,
      {bool verify = false,
      bool raw = false,
      bool? throwOnError,
      int? maxOutputSize}) {
    if (maxOutputSize == null) {
      return platformZLibDecoder.decodeBytes(bytes,
          verify: verify, raw: raw, throwOnError: throwOnError);
    }
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(bytes), output,
        verify: verify,
        raw: raw,
        throwOnError: throwOnError,
        maxOutputSize: maxOutputSize);
    return output.getBytes();
  }

  /// Decompress the given [input] with the ZLib format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// If [raw] is true, the input will be considered deflate compressed data
  /// without a zlib header.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only `verify` finds a cut stream: `ArchiveChecksumException`.
  /// Over 4 KB of bytes after the stream also read as a wrong checksum there.
  /// Neither flag finds a cut [raw] stream there: it has no checksum.
  ///
  /// {@macro archive.max_output_size.stream}
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false,
          bool raw = false,
          bool? throwOnError,
          int? maxOutputSize}) =>
      decodeLimited(
          output,
          maxOutputSize,
          (output) => platformZLibDecoder.decodeStream(input, output,
              verify: verify, raw: raw, throwOnError: throwOnError));

  /// {@macro archive.decode_lazy}
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      platformZLibDecoder.decodeLazy(input, verify: verify, raw: raw);
}

import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
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
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only a single member gzip gets `ArchiveChecksumException`.
  ///
  /// {@macro archive.max_output_size.bytes}
  Uint8List decodeBytes(List<int> bytes,
      {bool verify = false, bool throwOnError = false, int? maxOutputSize}) {
    if (maxOutputSize == null) {
      return platformGZipDecoder.decodeBytes(bytes,
          verify: verify, throwOnError: throwOnError);
    }
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(bytes), output,
        verify: verify,
        throwOnError: throwOnError,
        maxOutputSize: maxOutputSize);
    return output.getBytes();
  }

  /// Decompress the given [input] with the GZip format, writing the
  /// decompressed data to the [output] stream.
  /// Returns false if the archive is malformed or truncated, in which case
  /// [output] holds however much was decoded before the failure and should be
  /// discarded.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only a single member gzip gets `ArchiveChecksumException`.
  ///
  /// {@macro archive.max_output_size.stream}
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false,
          bool throwOnError = false,
          int? maxOutputSize}) =>
      decodeLimited(
          output,
          maxOutputSize,
          (output) => platformGZipDecoder.decodeStream(input, output,
              verify: verify, throwOnError: throwOnError));

  /// {@macro archive.decode_lazy}
  ///
  /// The length recorded in each member's trailer is checked; the CRC is
  /// checked where the decoder underneath does so.
  InputStream decodeLazy(InputStream input, {bool verify = false}) =>
      platformGZipDecoder.decodeLazy(input, verify: verify);
}

import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
import '../util/input_decode_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'tar_decoder.dart';
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
  ///
  /// This has no way to report a failure, so a truncated archive yields
  /// however much decoded before the data ran out, with nothing to say it is
  /// not the whole thing. Use [decodeStream] where that matters.
  ///
  /// With [maxOutputSize], an [ArchiveException] is thrown as soon as the
  /// decoded data would pass that many bytes, rather than decoding a small
  /// input that expands without limit.
  Uint8List decodeBytes(List<int> bytes,
      {bool verify = false, int? maxOutputSize}) {
    if (maxOutputSize == null) {
      return platformGZipDecoder.decodeBytes(bytes, verify: verify);
    }
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(bytes), output,
        verify: verify, maxOutputSize: maxOutputSize);
    return output.getBytes();
  }

  /// Decompress the given [input] with the GZip format, writing the
  /// decompressed data to the [output] stream.
  /// [verify] can be used to validate the checksum of the decompressed data,
  /// though it is not guaranteed this will be used.
  ///
  /// Returns false if the archive is malformed or truncated, in which case
  /// [output] holds however much was decoded before the failure and should be
  /// discarded. Damage within the compressed data is reported by the
  /// underlying decoder as a [FormatException] instead.
  ///
  /// With [maxOutputSize], an [ArchiveException] is thrown as soon as more
  /// than that many bytes would be written to [output].
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false, int? maxOutputSize}) =>
      decodeLimited(
          output,
          maxOutputSize,
          (output) =>
              platformGZipDecoder.decodeStream(input, output, verify: verify));

  /// Returns an [InputStream] that decompresses [input] as it is read.
  ///
  /// Nothing is decoded until the returned stream is read, and only a window
  /// of the decoded data is held in memory, so a multi-gigabyte `.gz` can be
  /// fed to another decoder, such as [TarDecoder], without a temp file. The
  /// stream is read forwards: see [InputDecodeStream] for what that means.
  ///
  /// A malformed or truncated input throws an [ArchiveException] from the
  /// read that runs into it. The length recorded in each member's trailer is
  /// checked; the CRC is checked where the decoder underneath does so.
  InputStream decodeLazy(InputStream input, {bool verify = false}) =>
      platformGZipDecoder.decodeLazy(input, verify: verify);
}

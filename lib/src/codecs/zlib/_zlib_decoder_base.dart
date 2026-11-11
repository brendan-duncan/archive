import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';

/// A buffer to inflate [compressed] bytes into when the size they inflate to
/// is not known. Under 8 KB of input it starts at four times the input, which
/// holds most text without growing, where the 32 KB default for each of 20000
/// entries of 200 bytes took 139 ms to inflate them, not 77 ms
OutputMemoryStream inflateBuffer(int compressed) =>
    OutputMemoryStream(size: inflateBufferSize(compressed));

/// The size [inflateBuffer] starts at, or null for the default
int? inflateBufferSize(int compressed) =>
    compressed >= 0 && compressed < OutputMemoryStream.defaultBufferSize ~/ 4
        ? (compressed < 16 ? 64 : compressed * 4)
        : null;

abstract class ZLibDecoderBase {
  const ZLibDecoderBase();

  Uint8List decodeBytes(List<int> bytes,
      {bool verify = false, bool raw = false, bool? throwOnError});

  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool? throwOnError});

  InputStream decodeLazy(InputStream input,
      {bool verify = false, bool raw = false});
}

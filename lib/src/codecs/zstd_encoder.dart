import 'dart:typed_data';

import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_frame_encoder.dart';

export 'zstd/zstd_frame_encoder.dart' show zstdMaxLevel, zstdMinLevel;

/// The level [ZstdEncoder] compresses at unless told otherwise, the same as
/// the reference library's.
const int zstdDefaultLevel = 3;

/// Compress data in the zstd (Zstandard) format.
///
/// Levels run from [zstdMinLevel], the fastest, to [zstdMaxLevel], the
/// smallest output, and zero means [zstdDefaultLevel], as in the reference
/// library. Levels 1 to 4 use fast hash table match finders, 5 to 14 a row
/// based search like the reference library's, and 15 up a hash chain that is
/// searched deeper with each level. Up to about level 15 the output is close
/// to the size the reference library produces at the same level. At the
/// highest levels it is up to 15% larger, the reference library having an
/// optimal parser there that this encoder does not. Levels from 20 use
/// windows of 32 MB and up, which a decoder has to hold in memory.
///
/// The output is always a single frame, with the content size in its header.
class ZstdEncoder {
  /// Compresses [data].
  ///
  /// [checksum] appends a checksum of the content to the frame, which a
  /// decoder can verify. Off by default, as in the reference library's
  /// API, though its command line tool turns it on.
  Uint8List encodeBytes(List<int> data,
      {int level = zstdDefaultLevel, bool checksum = false}) {
    final output = OutputMemoryStream();
    encodeStream(InputMemoryStream(data), output,
        level: level, checksum: checksum);
    return output.getBytes();
  }

  /// Compresses everything left in [input], writing it to [output].
  void encodeStream(InputStream input, OutputStream output,
      {int level = zstdDefaultLevel, bool checksum = false}) {
    if (level < zstdMinLevel || level > zstdMaxLevel) {
      throw ArgumentError.value(
          level, 'level', 'Must be between $zstdMinLevel and $zstdMaxLevel');
    }
    ZstdFrameEncoder(level == 0 ? zstdDefaultLevel : level, checksum)
        .encode(input, output);
  }
}

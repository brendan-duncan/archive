import 'dart:typed_data';

import '../../util/input_stream.dart';
import 'xz_index.dart';
import 'xz_stream_decoder.dart';

/// Needs to be reviewed for WASM in a year or two, isolated might land there
/// by that time #55364
const bool xzIsolatesSupported = false;

/// A stretch of a file on disk holding an xz archive.
class XZFileRegion {
  final String path;
  final int offset;
  final int length;

  const XZFileRegion(this.path, this.offset, this.length);
}

/// Always null here: there are no files to read blocks from.
XZFileRegion? xzFileRegionOf(InputStream input) => null;

/// Never called on this platform; [xzFileRegionOf] never returns a region.
XZLayout? xzLayoutOfFile(XZFileRegion region, {int? maxUncompressedSize}) =>
    null;

/// Never called on this platform
Stream<Uint8List> xzDecodeStreamMultithreaded(Stream<List<int>> input,
        {required bool verify, int? workers, int? memoryBudget}) =>
    throw UnsupportedError('Isolates are not available on this platform');

/// Never called on this platform
Future<bool> xzDecodeMultithreaded({
  Uint8List? bytes,
  String? path,
  int fileOffset = 0,
  int fileLength = 0,
  required XZLayout? layout,
  required bool verify,
  required int maxPreallocateSize,
  int maxDictionarySize = xzDefaultMaxDictionarySize,
  int? workers,
  int? memoryBudget,
  required void Function(int outputOffset, Uint8List chunk) onChunk,
  void Function(int block, bool ok)? onBlockDone,
  void Function(String reason)? onFailureReason,
  bool orderedOutput = false,
  required int fileReadBufferSize,
}) =>
    throw UnsupportedError('Isolates are not available on this platform');

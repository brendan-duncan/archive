import 'dart:typed_data';

import 'input_stream.dart';
import 'output_stream.dart';

const _piece = 64 * 1024;

/// Writes [stream] from its position to its end into [output] a piece at a
/// time, and puts its position back, as [OutputStream.writeStream] promises.
///
/// It reads [stream] itself rather than a subset of it, so a stream that does
/// something as it is read, such as keeping a checksum of the bytes, sees them
/// go by. [stream] must not be an `InputDecodeStream`, whose [length] decodes
/// everything that is left.
void copyStreamInPieces(InputStream stream, OutputStream output) {
  final held = stream.position;
  try {
    final left = stream.length;
    if (left <= 0) {
      return;
    }
    // A small stream, such as a tar header, gets a buffer its own size
    final scratch = Uint8List(left < _piece ? left : _piece);
    while (!stream.isEOS) {
      final got = stream.readInto(scratch, 0, scratch.length);
      if (got <= 0) {
        break;
      }
      output.writeBytes(scratch, length: got);
    }
  } finally {
    stream.setPosition(held);
  }
}

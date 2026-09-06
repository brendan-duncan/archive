import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';

const platformGZipDecoder = _GZipDecoder();

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  const _GZipDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
          {bool verify = false, bool raw = false}) =>
      GZipCodec().decode(data) as Uint8List;

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false}) {
    // Counted here rather than read back off [output], whose length is its own
    // business: this is the number of bytes this call put there.
    var written = 0;
    // The last eight bytes of the input, kept as a sliding window so that
    // nothing has to be seeked or held on to. See the check after the loop for
    // what they are for.
    final trailer = Uint8List(8);
    var trailerLength = 0;
    // Whether the input opened with the gzip signature, which decides whether
    // the trailer check below applies at all.
    var isGZip = false;
    var seen = 0;

    final outSink = ChunkedConversionSink<List<int>>.withCallback((chunks) {
      for (final chunk in chunks) {
        output.writeBytes(chunk);
        written += chunk.length;
      }
      output.flush();
    });

    final inSink = GZipCodec().decoder.startChunkedConversion(outSink);

    while (!input.isEOS) {
      final chunkSize = min(8 * 1024, input.length);
      final chunk = input.readBytes(chunkSize).toUint8List();
      if (chunk.isNotEmpty) {
        if (seen == 0) {
          isGZip = chunk[0] == 0x1f && (chunk.length < 2 || chunk[1] == 0x8b);
        } else if (seen == 1) {
          isGZip = isGZip && chunk[0] == 0x8b;
        }
        seen += chunk.length;
        final keep = min(8, chunk.length);
        if (keep < 8) {
          trailer.setRange(0, 8 - keep, trailer, keep);
        }
        trailer.setRange(8 - keep, 8, chunk, chunk.length - keep);
        trailerLength = min(8, trailerLength + chunk.length);
      }
      inSink.add(chunk);
    }
    inSink.close();

    // The decoder underneath checks the CRC and the length of every member
    // whose trailer it reaches, and rejects trailing bytes that do not begin
    // another member. What it does not reject is a member cut short before its
    // trailer: that decodes to a short result and reports success, which is a
    // truncated archive silently losing files.
    //
    // A member's last four bytes are its uncompressed length modulo 2^32, so
    // for a whole stream it cannot exceed what was written: equal for the one
    // member that a .gz or .tar.gz holds, less when members are concatenated.
    // In a truncated stream those four bytes are compressed data instead, and
    // land above the total unless they happen to read as a number the output
    // is long enough to cover, which for an output of n bytes is a chance of
    // n / 2^32. Past 4 GB of output the comparison stops saying anything,
    // since every value is then in range.
    //
    // None of this applies to an input that never had a gzip header: the
    // decoder underneath accepts a plain zlib stream too, and its trailer is
    // four bytes of Adler-32 that would fail this on sight. That case is left
    // reported the way it always was.
    if (seen == 0) {
      // Nothing at all is not a gzip stream, and not a zlib one either: the
      // shortest of those is two bytes.
      return false;
    }
    if (!isGZip) {
      return true;
    }
    if (trailerLength < 8) {
      return false;
    }
    final declared = trailer[4] |
        (trailer[5] << 8) |
        (trailer[6] << 16) |
        (trailer[7] << 24);
    return written >= 0x100000000 || declared <= written;
  }
}

import '../../util/output_stream.dart';

/// How much of the input to hand the native codec at a time.
///
/// Measured on a 1 GB file to file gzip: 64 KB chunks encode 23% faster and
/// decode 12% faster than the 1 KB and 8 KB chunks used before, and larger
/// chunks gain nothing more.
const int zlibChunkSize = 64 * 1024;

/// A sink for the native zlib codecs that writes each chunk to an
/// [OutputStream] as it arrives.
///
/// `ChunkedConversionSink.withCallback` looks like the obvious choice, but it
/// collects every chunk in a list and only hands them over on close, which
/// means the whole decompressed output sits in memory before the first byte
/// reaches the stream. Decoding a 1 GB gzip through it peaked at 1 GB of RSS;
/// through this sink it peaks at 24 MB.
class OutputStreamSink implements Sink<List<int>> {
  final OutputStream output;

  /// Bytes written through this sink so far.
  int written = 0;

  OutputStreamSink(this.output);

  @override
  void add(List<int> data) {
    output.writeBytes(data);
    written += data.length;
  }

  @override
  void close() => output.flush();
}

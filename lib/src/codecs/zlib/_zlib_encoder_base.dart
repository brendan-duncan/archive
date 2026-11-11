import 'dart:convert';
import 'dart:typed_data';

import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';

/// The length of [input] where it is known without reading it, which lets
/// `Deflate` size its tables to a small input. The length of a lazily decoded
/// stream decodes all of it, so only a stream in memory is asked
int? deflateInputSize(InputStream input) =>
    input is InputMemoryStream ? input.length : null;

/// The size of the buffer [length] bytes are deflated into, or null for the
/// default. A small input gets room for itself and a header, not 32 KB
int? deflateBufferSize(int length) =>
    length < OutputMemoryStream.defaultBufferSize ? length + 64 : null;

abstract class ZLibEncoderBase {
  const ZLibEncoderBase();

  Uint8List encodeBytes(List<int> bytes,
      {int? level, int? windowBits, bool raw = false});

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false});

  /// A sink that compresses into [output] piece by piece.
  Sink<List<int>>? startEncode(OutputStream output,
          {int? level, int? windowBits, bool raw = false}) =>
      null;
}

/// Sends every piece the codec produces straight to [output], where
/// `ChunkedConversionSink.withCallback` would hold the whole of it to the end
class ZLibOutputSink implements Sink<List<int>> {
  final OutputStream _output;

  /// Number of bytes this sink has written to [_output]; [_output] may already
  /// hold other data, so its length can be larger
  var written = 0;

  /// Checksum of the written bytes, updated when [update] is set
  var value = 0;
  int Function(List<int> data, int value)? update;

  ZLibOutputSink(this._output);

  @override
  void add(List<int> data) {
    _output.writeBytes(data);
    written += data.length;
    final update = this.update;
    if (update != null) {
      value = update(data, value);
    }
  }

  @override
  void close() => _output.flush();
}

bool convertKeepingPartial(Converter<List<int>, List<int>> decoder,
    Uint8List bytes, int end, OutputMemoryStream partial,
    {List<int>? trailer}) {
  final sink = decoder.startChunkedConversion(ZLibOutputSink(partial));
  if (sink is ByteConversionSink) {
    sink.addSlice(bytes, 0, end, false);
  } else {
    sink.add(Uint8List.sublistView(bytes, 0, end));
  }
  var accepted = true;
  if (trailer != null) {
    accepted = addTrailerUnchecked(sink, trailer);
  }
  sink.close();
  return accepted;
}

bool addTrailerUnchecked(Sink<List<int>> sink, List<int> trailer) {
  if (trailer.isEmpty) {
    return true;
  }
  try {
    sink.add(trailer);
  } on FormatException {
    // This catch also hides garbage after gzip member: throwOnError accepts 8
    // or 9 trailing zero bytes, while verify rejects them. Only second inflate
    // pass finds where member ends, and it is too slow for this rare case
    return false;
  }
  return true;
}

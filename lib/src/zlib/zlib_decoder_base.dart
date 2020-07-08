import '../util/input_stream.dart';

/// Decompress data with the zlib format decoder.
class ZLibDecoderBase {
  List<int> decodeBytes(List<int> data,
      {bool verify = false, bool raw = false}) {
    return null;
  }

  List<int> decodeBuffer(InputStream input,
      {bool verify = false, bool raw = false}) {
    return null;
  }
}

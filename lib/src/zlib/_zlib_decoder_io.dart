import 'dart:io';
import '../util/input_stream.dart';
import 'zlib_decoder_base.dart';


ZLibDecoderBase createZLibDecoder() => new _ZLibDecoder();

/**
 * Decompress data with the zlib format decoder.
 */
class _ZLibDecoder extends ZLibDecoderBase {
  List<int> decodeBytes(List<int> data, {bool verify: false}) {
    return new ZLibCodec().decoder.convert(data);
  }

  List<int> decodeBuffer(InputStream input, {bool verify: false}) {
    return decodeBytes(input.toUint8List(), verify: verify);
  }
}


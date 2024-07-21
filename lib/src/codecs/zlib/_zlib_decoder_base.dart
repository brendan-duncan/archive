import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

abstract class ZLibDecoderBase {
  const ZLibDecoderBase();

  Uint8List decodeBytes(List<int> bytes, {bool verify = false});

  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false});
}

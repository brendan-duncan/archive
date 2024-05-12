import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

abstract class ZLibEncoderBase {
  const ZLibEncoderBase();

  Uint8List encodeBytes(List<int> bytes, {int? level});

  void encodeStream(InputStream input, OutputStream output, {int? level});
}

import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

const platformZLibEncoder = _ZLibEncoder();

class _ZLibEncoder {
  const _ZLibEncoder();

  Uint8List encode(List<int> bytes, {int level = 6}) =>
      ZLibCodec(level: level).encoder.convert(bytes) as Uint8List;

  void encodeStream(InputStream input, OutputStream output, {int level = 6}) {
    final encoded = encode(input.toUint8List(), level: level);
    output.writeBytes(encoded);
  }
}

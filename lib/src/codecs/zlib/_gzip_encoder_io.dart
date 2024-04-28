import 'dart:io';
import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

const platformGZipEncoder = _GZipEncoder();

class _GZipEncoder {
  const _GZipEncoder();

  Uint8List encode(List<int> bytes, {int level = 6}) =>
      GZipCodec(level: level).encode(bytes) as Uint8List;

  void encodeStream(InputStream input, OutputStream output, {int level = 6}) {
    final encoded = encode(input.toUint8List(), level: level);
    output.writeBytes(encoded);
  }
}

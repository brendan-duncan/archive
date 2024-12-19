import 'dart:async';
import 'dart:typed_data';

import '_inflate_buffer_web.dart'
    if (dart.library.io) '_inflate_buffer_io.dart';

FutureOr<Uint8List>? inflateBuffer(List<int> data) => inflateBuffer_(data);

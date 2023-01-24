import 'dart:async';
import 'dart:typed_data';

import 'inflate.dart';

FutureOr<Uint8List>? inflateBuffer_(Uint8List data) => Inflate(data).getBytes();

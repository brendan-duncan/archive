import 'dart:typed_data';

import 'inflate.dart';

Uint8List? inflateBuffer_(Uint8List data) => Inflate(data).getBytes();

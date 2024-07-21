import 'dart:typed_data';

import 'inflate.dart';

Uint8List? inflateBuffer_(List<int> data) => Inflate(data).getBytes();

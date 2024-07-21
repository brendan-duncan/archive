import 'dart:io';
import 'dart:typed_data';

Uint8List? inflateBuffer_(List<int> data) =>
    ZLibDecoder(raw: true).convert(data) as Uint8List;

import 'dart:io';
import 'dart:typed_data';

Uint8List? inflateBuffer_(Uint8List data) =>
    ZLibDecoder(raw: true).convert(data) as Uint8List;

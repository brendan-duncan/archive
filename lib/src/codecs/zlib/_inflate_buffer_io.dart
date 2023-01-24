import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

FutureOr<Uint8List>? inflateBuffer_(Uint8List data) =>
    ZLibDecoder(raw: true).convert(data) as Uint8List;

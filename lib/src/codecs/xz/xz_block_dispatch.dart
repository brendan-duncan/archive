import 'dart:typed_data';

/// Where a streamed xz decoder sends the blocks it does not decode itself
abstract class XzBlockDispatch {
  int get maxBlockBytes;

  void block(Uint8List bytes, int streamFlags, int uncompressedLength,
      int dictionarySize);

  bool get idle;
}

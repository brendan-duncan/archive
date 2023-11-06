import 'dart:io';

List<int>? inflateBuffer_(List<int> data) {
  return ZLibDecoder(raw: true).convert(data);
}

bool useNativeZLib_() {
  return true;
}

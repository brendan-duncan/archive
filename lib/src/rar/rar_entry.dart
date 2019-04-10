class RarMethod {
  static const store = 0x30;
  static const fastest = 0x31;
  static const fast = 0x32;
  static const normal = 0x33;
  static const good = 0x34;
  static const best = 0x35;
}

class RarEntry {
  String name;
  String path;
  int size;
  int sizePacked;
  int crc;
  int offset;
  int blockSize;
  int headerSize;
  bool encrypted;
  int version;
  DateTime time;
  int method;
  String os;
  bool partial;
  bool continuesFrom;
  bool continues;
}

part of dart_archive;

class TarDecoder {
  TarDecoder(List<int> data) {
    _ByteBuffer input = new _ByteBuffer.read(data);
  }

  bool isValidFile() {
    return false;
  }

  int numberOfFiles() {
    return 0;
  }

  String fileName(int index) {
    return '';
  }

  int fileSize(int index) {
    return 0;
  }

  List<int> fileData(int index) {
    return null;
  }
}

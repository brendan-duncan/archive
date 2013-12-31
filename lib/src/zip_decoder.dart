part of archive;

class ZipDecoder {
  ZipDirectory directory;

  ZipDecoder(List<int> data) {
    InputBuffer input = new InputBuffer(data);
    directory = new ZipDirectory(input);
  }

  bool isValidFile() {
    return directory != null;
  }

  int numberOfFiles() {
    return directory.fileHeaders.length;
  }

  String fileName(int index) {
    return directory.fileHeaders[index].filename;
  }

  int fileSize(int index) {
    return directory.fileHeaders[index].uncompressedSize;
  }

  List<int> fileData(int index) {
    return directory.fileHeaders[index].file.content;
  }
}

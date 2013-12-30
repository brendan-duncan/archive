part of dart_archive;

class TarDecoder {
  List<TarFile> files = [];

  TarDecoder(List<int> data) {
    InputBuffer input = new InputBuffer(data);
    while (!input.isEOF) {
      try {
        // End of archive.
        if (input.buffer[input.position] == 0 &&
            input.buffer[input.position + 1] == 0) {
          break;
        }

        TarFile file = new TarFile(input);

        files.add(file);
      } catch (error) {
        break;
      }
    }
  }

  bool isValidFile() {
    return files.isNotEmpty;
  }

  int numberOfFiles() {
    return files.length;
  }

  String fileName(int index) {
    return files[index].filename;
  }

  int fileSize(int index) {
    return files[index].fileSize;
  }

  List<int> fileData(int index) {
    return files[index].data;
  }
}

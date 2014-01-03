part of archive;

class Archive {
  List<File> files = [];
  String comment;

  void addFile(File file) {
    files.add(file);
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
    return files[index].content;
  }
}

part of dart_archive;

class ZipArchive extends Archive {
  void open(List<int> data) {

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

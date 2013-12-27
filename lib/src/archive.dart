part of dart_archive;


abstract class ArchiveDecoder {
  void open(List<int> data);

  bool isValidFile();

  int numberOfFiles();

  String fileName(int index);

  int fileSize(int index);

  List<int> fileData(int index);
}

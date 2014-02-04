part of archive;

/**
 * A collection of files.
 */
class Archive extends IterableBase<File> {
  /// The list of files in the archive.
  List<File> files = [];
  /// A global comment for the archive.
  String comment;

  /**
   * Add a file to the archive.
   */
  void addFile(File file) {
    files.add(file);
  }

  /**
   * The number of files in the archive.
   */
  int get length => files.length;

  /**
   * Get a file from the archive.
   */
  File operator[](int index) => files[index];

  /**
   * Find a file with the given [name] in the archive. If the file isn't found,
   * null will be returned.
   */
  File findFile(String name) {
    for (File f in files) {
      if (f.filename == name) {
        return f;
      }
    }
    return null;
  }

  /**
   * The number of files in the archive.
   */
  int numberOfFiles() {
    return files.length;
  }

  /**
   * The name of the file at the given [index].
   */
  String fileName(int index) {
    return files[index].filename;
  }

  /**
   * The decompressed size of the file at the given [index].
   */
  int fileSize(int index) {
    return files[index].fileSize;
  }

  /**
   * The decompressed data of the file at the given [index].
   */
  List<int> fileData(int index) {
    return files[index].content;
  }


  File get first => files.first;

  File get last => files.last;

  bool get isEmpty => files.isEmpty;

  // Returns true if there is at least one element in this collection.
  bool get isNotEmpty => files.isNotEmpty;

  Iterator<File> get iterator => files.iterator;
}

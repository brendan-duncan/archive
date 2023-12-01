import 'archive_file.dart';
import 'dart:collection';

/// A collection of files
class Archive extends IterableBase<ArchiveFile> {
  /// The list of files in the archive.
  final List<ArchiveFile> _files = [];
  final Map<String, int> _fileMap = {};

  /// A global comment for the archive.
  String? comment;

  /// Unmodifiable view of the files in the archive.
  List<ArchiveFile> get files => UnmodifiableListView(_files);

  /// Add a file to the archive.
  void addFile(ArchiveFile file) {
    // Adding a file with the same path as one that's already in the archive
    // will replace the previous file.
    var index = _fileMap[file.name];
    if (index != null) {
      _files[index] = file;
      return;
    }
    // No existing file was in the archive with the same path, add it to the
    // archive.
    _files.add(file);
    _fileMap[file.name] = _files.length - 1;
  }

  Future<void> clear() async {
    var futures = <Future<void>>[];
    for (var fp in _files) {
      futures.add(fp.close());
    }
    _files.clear();
    _fileMap.clear();
    comment = null;
    await Future.wait(futures);
  }

  /// The number of files in the archive.
  @override
  int get length => _files.length;

  /// Get a file from the archive.
  ArchiveFile operator [](int index) => _files[index];

  /// Find a file with the given [name] in the archive. If the file isn't found,
  /// null will be returned.
  ArchiveFile? findFile(String name) {
    var index = _fileMap[name];
    return index != null ? _files[index] : null;
  }

  /// The number of files in the archive.
  int numberOfFiles() {
    return _files.length;
  }

  /// The name of the file at the given [index].
  String fileName(int index) {
    return _files[index].name;
  }

  /// The decompressed size of the file at the given [index].
  int fileSize(int index) {
    return _files[index].size;
  }

  /// The decompressed data of the file at the given [index].
  List<int> fileData(int index) {
    return _files[index].content as List<int>;
  }

  @override
  ArchiveFile get first => _files.first;

  @override
  ArchiveFile get last => _files.last;

  @override
  bool get isEmpty => _files.isEmpty;

  // Returns true if there is at least one element in this collection.
  @override
  bool get isNotEmpty => _files.isNotEmpty;

  @override
  Iterator<ArchiveFile> get iterator => _files.iterator;
}

import 'dart:collection';
import 'dart:typed_data';

import 'archive_file.dart';

//// A collection of files
class Archive extends IterableBase<ArchiveFile> {
  /// The list of files in the archive.
  final List<ArchiveFile> _files = [];
  final Map<String, int> _fileMap = {};

  /// A global comment for the archive.
  String? comment;

  /// Unmodifiable view of the files in the archive.
  List<ArchiveFile> get files => UnmodifiableListView(_files);

  /// Add a file or directory to the archive.
  void add(ArchiveFile file) {
    // Adding a file with the same path as one that's already in the archive
    // will replace the previous file.
    final index = _fileMap[file.name];
    if (index != null) {
      _files[index] = file;
      return;
    }
    // No existing file was in the archive with the same path, add it to the
    // archive.
    _files.add(file);
    _fileMap[file.name] = _files.length - 1;
  }

  void modifyAtIndex(int index, ArchiveFile file) {
    _files[index] = file; // Modify the underlying list
  }

  /// Alias for [add] for backwards compatibility.
  void addFile(ArchiveFile file) => add(file);

  void removeFile(ArchiveFile file) {
    final index = _fileMap[file.name];
    if (index != null) {
      _files.removeAt(index);
      _fileMap.remove(file.name);
      // Indexes have changed, update the file map.
      _updateFileMap();
    }
  }

  void removeAt(int index) {
    if (index < 0 || index >= _files.length) {
      return;
    }
    _fileMap.remove(_files[index].name);
    _files.removeAt(index);
    // Indexes have changed, update the file map.
    _updateFileMap();
  }

  Future<void> clear() async {
    var futures = <Future<void>>[for (var fp in _files) fp.close()];
    _files.clear();
    _fileMap.clear();
    comment = null;
    await Future.wait(futures);
  }

  void clearSync() {
    for (var fp in _files) {
      fp.closeSync();
    }
    _files.clear();
    _fileMap.clear();
    comment = null;
  }

  /// The number of files in the archive.
  @override
  int get length => _files.length;

  /// Get a file from the archive.
  ArchiveFile operator [](int index) => _files[index];

  /// Set a file in the archive.
  void operator []=(int index, ArchiveFile file) {
    if (index < 0 || index >= _files.length) {
      return;
    }
    _fileMap.remove(_files[index].name);
    _files[index] = file;
    _fileMap[file.name] = index;
  }

  /// Find a file with the given [name] in the archive. If the file isn't found,
  /// null will be returned.
  ArchiveFile? find(String name) {
    var index = _fileMap[name];
    return index != null ? _files[index] : null;
  }

  /// Alias for [find], for backwards compatibility.
  ArchiveFile? findFile(String name) => find(name);

  /// The number of files in the archive.
  int numberOfFiles() => _files.length;

  /// The name of the file at the given [index].
  String fileName(int index) => _files[index].name;

  /// The decompressed size of the file at the given [index].
  int fileSize(int index) => _files[index].size;

  /// The decompressed data of the file at the given [index].
  Uint8List fileData(int index) => _files[index].content;

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

  void _updateFileMap() {
    _fileMap.clear();
    for (var i = 0; i < _files.length; i++) {
      _fileMap[_files[i].name] = i;
    }
  }
}

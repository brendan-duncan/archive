import '../util/archive_exception.dart';
import 'archive_entry.dart';

class ArchiveDirectory extends ArchiveEntry {
  final entries = <ArchiveEntry>[];
  final entryMap = <String, int>{};

  ArchiveDirectory(String name) : super(name: name, mode: 0x1ff);

  @override
  bool get isFile => false;

  @override
  Future<void> close() async {
    final futures = <Future<void>>[];
    for (final fp in entries) {
      futures.add(fp.close());
    }
    await Future.wait(futures);
  }

  @override
  void closeSync() {
    for (final fp in entries) {
      fp.closeSync();
    }
  }

  /// Add a file to the archive.
  void add(ArchiveEntry entry) {
    // Adding a file with the same path as one that's already in the archive
    // will replace the previous file.
    final index = entryMap[entry.name];
    if (index != null) {
      entries[index] = entry;
      return;
    }
    // No existing file was in the archive with the same path, add it to the
    // archive.
    entries.add(entry);
    entryMap[entry.name] = entries.length - 1;
    entry.parent = this;
  }

  ArchiveDirectory? getOrCreateDirectory(String name) {
    final index = entryMap[name];
    if (index != null) {
      final entry = entries[index];
      if (entry is ArchiveDirectory) {
        return entry;
      }
      throw ArchiveException('Invalid archive');
    }
    final dir = ArchiveDirectory(name);
    entryMap[name] = entries.length;
    entries.add(dir);
    dir.parent = this;
    return dir;
  }

  Future<void> clear() async {
    await close();
    entries.clear();
    entryMap.clear();
    comment = null;
  }

  void clearSync() {
    closeSync();
    entries.clear();
    entryMap.clear();
    comment = null;
  }

  /// The number of files in the archive.
  @override
  int get length => entries.length;

  /// Get a file from the archive.
  @override
  ArchiveEntry operator [](int index) => entries[index];

  /// Find a file with the given [name] in the archive. If the file isn't found,
  /// null will be returned.
  ArchiveEntry? find(String name) {
    final index = entryMap[name];
    return index != null ? entries[index] : null;
  }

  @override
  ArchiveEntry get first => entries.first;

  @override
  ArchiveEntry get last => entries.last;

  @override
  bool get isEmpty => entries.isEmpty;

  // Returns true if there is at least one element in this collection.
  @override
  bool get isNotEmpty => entries.isNotEmpty;

  @override
  Iterator<ArchiveEntry> get iterator => entries.iterator;
}

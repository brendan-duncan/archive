import 'package:path/path.dart' as p;
import 'archive_entry.dart';
import 'archive_file.dart';

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

  ArchiveDirectory? _getOrCreateDirectory(String name) {
    final index = entryMap[name];
    if (index != null) {
      final entry = entries[index];
      if (entry is ArchiveDirectory) {
        return entry;
      }
      return null;
    }
    final dir = ArchiveDirectory(name);
    entryMap[name] = entries.length;
    entries.add(dir);
    dir.parent = this;
    return dir;
  }

  /// Get or create an [ArchiveDirectory] container for the given [path].
  /// Directories are created recursively as necessary.
  /// If [isFile] is true, then [path] is a file path and the file name will
  /// not be included in creating directories.
  /// If the [path] points to an [ArchiveFile], then null will be returned.
  ArchiveDirectory? getOrCreateDirectory(String path, {bool isFile = true}) {
    final pathTk = p.split(path);
    if (pathTk.last.isEmpty) {
      pathTk.removeLast();
    }
    if (isFile) {
      pathTk.removeLast(); // Pop off the file name
    }
    if (pathTk.isNotEmpty) {
      var e = _getOrCreateDirectory(pathTk[0]);
      if (e != null) {
        for (var i = 1; i < pathTk.length; ++i) {
          e = e!.getOrCreateDirectory(pathTk[i], isFile: false)!;
        }
      }
      return e;
    }
    return null;
  }

  @override
  Future<void> clear() async {
    await close();
    entries.clear();
    entryMap.clear();
    comment = null;
  }

  @override
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
  ArchiveEntry? find(String path) {
    final pathTk = p.split(path);
    var dir = this;
    for (var i = 0; i < pathTk.length; ++i) {
      final name = pathTk[i];
      final index = dir.entryMap[name];
      if (index == null) {
        return null;
      }
      final x = entries[index];
      if (i == pathTk.length - 1) {
        return x;
      }
      if (x is! ArchiveDirectory) {
        return null;
      }
      dir = x;
    }
    return null;
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

  List<ArchiveEntry> getAllEntries([List<ArchiveEntry>? files]) {
    files ??= <ArchiveEntry>[];

    for (final e in entries) {
      if (e is ArchiveFile) {
        files.add(e);
      } else if (e is ArchiveDirectory) {
        files.add(e);
        e.getAllEntries(files);
      }
    }

    return files;
  }

  List<ArchiveFile> getAllFiles([List<ArchiveFile>? files]) {
    files ??= <ArchiveFile>[];

    for (final e in entries) {
      if (e is ArchiveFile) {
        files.add(e);
      } else if (e is ArchiveDirectory) {
        e.getAllFiles(files);
      }
    }

    return files;
  }
}

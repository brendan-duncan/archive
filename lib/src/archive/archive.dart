import 'package:path/path.dart' as p;
import 'archive_directory.dart';

/// A collection of files
class Archive extends ArchiveDirectory {
  Archive([super.name = '']) : super();

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
    return dir;
  }

  @override
  ArchiveDirectory? getOrCreateDirectory(String name) {
    final pathTk = p.split(name);
    if (pathTk.last.isEmpty) {
      pathTk.removeLast();
    }
    pathTk.removeLast();
    if (pathTk.isNotEmpty) {
      var e = _getOrCreateDirectory(pathTk[0]);
      if (e != null) {
        for (var i = 1; i < pathTk.length; ++i) {
          e = e!.getOrCreateDirectory(pathTk[i])!;
        }
      }
      return e;
    }
    return null;
  }
}

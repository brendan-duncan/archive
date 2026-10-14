import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';

String linkTarget(ArchiveFile file) => file.symbolicLink ?? '';

/// A hard link names its target from the archive root and a symlink from its
/// own folder. dart:io cannot make a hard link and a copy would double disk
/// use, so it becomes a symlink with the target rewritten from its folder
String hardLinkFromFolder(String name, String target) {
  String clean(String p) =>
      path.posix.normalize(p.replaceFirst(RegExp('^/+'), ''));
  try {
    return path.posix
        .relative(clean(target), from: path.posix.dirname(clean(name)));
  } on path.PathException {
    return target;
  }
}

String hardLinkFromRoot(String name, String target) =>
    path.posix.normalize(path.posix.join(path.posix.dirname(name), target));

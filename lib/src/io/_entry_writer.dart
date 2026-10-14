import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip/zip_file.dart';
import '../codecs/zstd_decoder.dart';
import '../util/_link_target.dart';
import '../util/archive_exception.dart';
import '../util/decode_guard.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
import '../util/output_stream.dart';
import 'posix.dart' as posix;

/// The tar inside [file], decompressed as it is read according to
/// [extension], as [getInputExtension] gives it, or null if [extension] is
/// not that of a tar.
InputStream? tarStreamFor(String extension, InputStream file) =>
    switch (extension) {
      '.tar.gz' || '.tgz' => GZipDecoder().decodeLazy(file),
      '.tar.bz2' || '.tbz' => BZip2Decoder().decodeLazy(file),
      '.tar.zst' || '.tzst' => ZstdDecoder().decodeLazy(file),
      '.tar.xz' || '.txz' => XZDecoder().decodeLazy(file),
      '.tar' => file,
      _ => null,
    };

/// Writes archive entries into [outputPath], keeping them inside it.
///
/// Symbolic links are created by [finish], after everything else, so that no
/// entry is ever written through a link the archive made. Without that, a
/// link `d -> .` followed by `d/e -> ..` passes a check made on the paths
/// alone, and a file `e/x` then lands outside [outputPath].
class EntryWriter {
  final String outputPath;
  final int? bufferSize;

  /// The most the files written may come to in all, or null for no limit.
  final int? maxSize;

  /// Whether to give each file the permissions stored for it.
  final bool setPermissions;

  final bool throwOnError;
  final bool allowAbsoluteSymlinks;
  Object? limitError;

  int _total = 0;
  late final String? _realOut;
  late final _OutputPaths _paths;
  final _delayed = <String, ArchiveFile>{};

  EntryWriter(this.outputPath,
      {this.bufferSize,
      this.maxSize,
      bool setPermissions = false,
      this.throwOnError = false,
      this.allowAbsoluteSymlinks = false})
      : setPermissions = setPermissions && posix.isPosixSupported() {
    _prepareOutDir(outputPath);
    _realOut = _realPath(outputPath);
    _paths = _OutputPaths(_realOut);
  }

  /// Writes [file], returning where, or null if it was refused for pointing
  /// outside [outputPath]. A link is only recorded here; see [finish].
  String? write(ArchiveFile file) {
    final filePath = _prepareArchiveFilePath(
        file, outputPath, _realOut, allowAbsoluteSymlinks, _paths, _delayed);
    if (filePath == null) {
      return null;
    }
    // A later archive entry could replace a parent directory with a symlink.
    // Like GNU tar, we defer creating and validating these links until the
    // entire tree is extracted
    if (file.isSymbolicLink) {
      if (!_delayLink(_delayed, filePath, file, _paths)) {
        return null;
      }
      return filePath;
    }
    final isFile = file.isFile && !file.isSymbolicLink;
    if (isFile) {
      try {
        _total = _addToTotal(_total, file.size, maxSize);
      } catch (error) {
        limitError = error;
        rethrow;
      }
    }
    final written = _extractArchiveEntryToDiskSync(file, filePath, _paths,
        bufferSize: bufferSize, throwOnError: throwOnError);
    if (!isFile) {
      return filePath;
    }
    if (written == null) {
      return null;
    }
    // The length of a lazily decoded tar is not known up front, so an
    // entry cut short by the end of the data is found here
    if (written < file.size) {
      File(filePath).deleteSync();
      throw ArchiveException('Unexpected end of tar data in ${file.name}');
    }
    if (setPermissions) {
      posix.chmod(filePath, file.unixPermissions.toRadixString(8));
    }
    return filePath;
  }

  /// Creates the links that [write] recorded.
  ///
  /// A link whose target resolves on disk outside [outputPath] is removed.
  /// Each is checked once all are made, since a link made later can sit in
  /// the path of one made earlier.
  void finish() => _createDelayedLinksSync(
      _delayed, outputPath, _realOut, allowAbsoluteSymlinks);
}

// Adds [size] to what has been written so far, refusing to go past [maxSize].
int _addToTotal(int total, int size, int? maxSize) {
  total += size;
  if (maxSize != null && total > maxSize) {
    throw ArchiveLimitException(
        'Extracting the archive would write more than $maxSize bytes');
  }
  return total;
}

/// canonicalize ignores symlinks out of outputPath, so we resolve them on disk
String? _realPath(String filePath,
    {bool followDangling = false, int depth = 0}) {
  var existing = path.absolute(filePath);
  final rest = <String>[];
  while (FileSystemEntity.typeSync(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    if (path.dirname(existing) == existing) {
      return path.canonicalize(filePath);
    }
    rest.insert(0, path.basename(existing));
    existing = path.dirname(existing);
  }
  try {
    return path.joinAll([File(existing).resolveSymbolicLinksSync(), ...rest]);
  } on FileSystemException {
    // A dangling symlink throws, so we follow its target ourselves. A loop
    // stops after 40 links, as on Linux, and the entry counts as outside
    if (!followDangling ||
        depth >= 40 ||
        FileSystemEntity.typeSync(existing, followLinks: false) !=
            FileSystemEntityType.link) {
      return null;
    }
    final target = Link(existing).targetSync();
    return _realPath(
        path.joinAll([
          path.isAbsolute(target)
              ? target
              : path.join(path.dirname(existing), target),
          ...rest
        ]),
        followDangling: true,
        depth: depth + 1);
  }
}

String _entryPath(String outputPath, String name) => path.join(
    outputPath, path.normalize(name.replaceFirst(_absolutePrefix, '')));

final _absolutePrefix = RegExp(
    r'^(?:[/\\]{2}(?:\?[/\\][Uu][Nn][Cc]|[.?])[/\\])?(?:[A-Za-z]:|[/\\])*');

bool _isValidSymLink(String outputPath, String? realOut, ArchiveFile file,
    bool allowAbsolute, _OutputPaths paths) {
  final filePath = path.dirname(_entryPath(outputPath, file.name));
  final linkPath = linkTarget(file);
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return allowAbsolute;
  }
  final realPath = paths.realDir(filePath);
  if (realPath == null || !paths.isRealWithin(path.join(realPath, linkPath))) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  return true;
}

/// Windows needs \ in a relative link target, and normalizing the text would
/// change where a link through another link points
String _linkText(ArchiveFile file) {
  final text = linkTarget(file);
  return Platform.isWindows ? text.replaceAll('/', r'\') : text;
}

bool _runsThroughDelayed(Map<String, ArchiveFile> delayed, String filePath) {
  if (delayed.isEmpty) {
    return false;
  }
  var dir = path.dirname(filePath);
  while (true) {
    if (delayed.containsKey(dir)) {
      return true;
    }
    final parent = path.dirname(dir);
    if (parent == dir) {
      return false;
    }
    dir = parent;
  }
}

bool _delayLink(Map<String, ArchiveFile> delayed, String filePath,
    ArchiveFile file, _OutputPaths paths) {
  if (!_clearForLink(filePath, paths)) {
    return false;
  }
  Directory(path.dirname(filePath)).createSync(recursive: true);
  delayed.remove(filePath);
  delayed[filePath] = file;
  return true;
}

void _createDelayedLinksSync(Map<String, ArchiveFile> delayed,
    String outputPath, String? realOut, bool allowAbsoluteSymlinks) {
  final created = <MapEntry<String, ArchiveFile>>[];
  for (final entry in delayed.entries.toList().reversed) {
    if (FileSystemEntity.typeSync(entry.key, followLinks: false) ==
        FileSystemEntityType.notFound) {
      Link(entry.key).createSync(_linkText(entry.value), recursive: true);
      created.add(entry);
    }
  }
  final paths = _OutputPaths(realOut);
  for (final MapEntry(key: filePath, value: file) in created) {
    if (!_isValidSymLink(
        outputPath, realOut, file, allowAbsoluteSymlinks, paths)) {
      Link(filePath).deleteSync();
      paths.cleared(true);
    }
  }
}

/// Caching is needed to reduce speed by 50%
class _OutputPaths {
  final String? realOut;
  final _dirs = <String, String?>{};
  final _inside = <String, bool>{};

  _OutputPaths(this.realOut);

  bool isEntryWithin(String filePath) {
    final dir = path.dirname(filePath);
    final name = path.basename(filePath);
    if (name == '.' || name == '..') {
      return _within(realDir(dir), filePath);
    }
    return _inside[dir] ??= _isInside(realDir(dir));
  }

  bool _isInside(String? real) =>
      realOut != null &&
      real != null &&
      (path.equals(realOut!, real) || path.isWithin(realOut!, real));

  String? realDir(String dir) {
    if (_dirs.containsKey(dir)) {
      return _dirs[dir];
    }
    final parent = path.dirname(dir);
    final name = path.basename(dir);
    final type = FileSystemEntity.typeSync(dir, followLinks: false);
    String? real;
    if (parent != dir &&
        name != '.' &&
        name != '..' &&
        (type == FileSystemEntityType.notFound ||
            type == FileSystemEntityType.directory)) {
      final realParent = realDir(parent);
      real =
          realParent == null ? null : path.join(realParent, path.basename(dir));
    } else {
      real = _realPath(dir);
    }
    _dirs[dir] = real;
    return real;
  }

  // Ensure filePath is contained in the outputDir folder, to make sure archives
  // aren't trying to write to some system path.
  bool isRealWithin(String filePath) {
    final name = path.basename(filePath);
    final String? real;
    if (name == '.' ||
        name == '..' ||
        FileSystemEntity.typeSync(filePath, followLinks: false) ==
            FileSystemEntityType.link) {
      real = _realPath(filePath, followDangling: true);
    } else {
      final realParent = realDir(path.dirname(filePath));
      real = realParent == null ? null : path.join(realParent, name);
    }
    return realOut != null && real != null && path.isWithin(realOut!, real);
  }

  bool _within(String? dir, String filePath) =>
      realOut != null &&
      dir != null &&
      path.isWithin(realOut!, path.join(dir, path.basename(filePath)));

  void cleared(bool link) {
    if (link) {
      _dirs.clear();
      _inside.clear();
    }
  }
}

void _createDirectory(String filePath) {
  try {
    Directory(filePath).createSync(recursive: true);
  } on FileSystemException {
    if (FileSystemEntity.typeSync(filePath, followLinks: false) !=
        FileSystemEntityType.file) {
      rethrow;
    }
    File(filePath).deleteSync();
    Directory(filePath).createSync(recursive: true);
  }
}

bool _clearPath(String filePath) {
  final type = FileSystemEntity.typeSync(filePath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    Link(filePath).deleteSync();
    return true;
  } else if (type == FileSystemEntityType.file) {
    File(filePath).deleteSync();
  }
  return false;
}

bool _clearForLink(String filePath, _OutputPaths paths) {
  if (FileSystemEntity.typeSync(filePath, followLinks: false) ==
      FileSystemEntityType.directory) {
    try {
      Directory(filePath).deleteSync();
    } on FileSystemException {
      return false;
    }
    return true;
  }
  paths.cleared(_clearPath(filePath));
  return true;
}

void _prepareOutDir(String outDirPath) {
  final outDir = Directory(outDirPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
}

String? _prepareArchiveFilePath(
    ArchiveFile archiveFile,
    String outputPath,
    String? realOut,
    bool allowAbsoluteSymlinks,
    _OutputPaths paths,
    Map<String, ArchiveFile> delayed) {
  final filePath = _entryPath(outputPath, archiveFile.name);

  if (!paths.isEntryWithin(filePath) ||
      _runsThroughDelayed(delayed, filePath)) {
    return null;
  }

  if (archiveFile.isSymbolicLink) {
    if (!_isValidSymLink(
        outputPath, realOut, archiveFile, allowAbsoluteSymlinks, paths)) {
      return null;
    }
  }

  return filePath;
}

void _writeStrict(ArchiveFile entry, OutputStream output) {
  final content = entry.rawContent;
  if (content is! ZipFile) {
    entry.writeContent(output);
    return;
  }
  final throwOnError = content.throwOnError;
  content.throwOnError = true;
  try {
    entry.writeContent(output);
  } finally {
    content.throwOnError = throwOnError;
  }
}

int? _extractArchiveEntryToDiskSync(
  ArchiveFile entry,
  String filePath,
  _OutputPaths paths, {
  int? bufferSize,
  bool throwOnError = false,
}) {
  if (entry.isFile) {
    paths.cleared(_clearPath(filePath));
    bufferSize ??= OutputFileStream.kDefaultBufferSize;
    // The buffer is allocated per file, so for a small file it is cut down
    // to the file's size rather than the full default. With 20,000 files of
    // 2 KB that is a quarter of the extraction time.
    final output = OutputFileStream(filePath,
        bufferSize: entry.size < bufferSize ? entry.size : bufferSize);
    try {
      _writeStrict(entry, output);
    } catch (error) {
      // A partial file from a failed entry looked extracted, so we delete
      // it
      try {
        output.closeSync();
      } catch (_) {}
      // Windows delete throws on an open file, so we ignore the error
      try {
        File(filePath).deleteSync();
      } catch (_) {}
      if (error is ArchivePasswordException ||
          error is ArchiveMacException ||
          error is ArchiveLimitException) {
        rethrow;
      }
      if (!isDecodeDataError(error)) {
        rethrow;
      }
      if (throwOnError) {
        rethrow;
      }
      return null;
    }
    output.closeSync();
    return output.length;
  }
  _createDirectory(filePath);
  return null;
}

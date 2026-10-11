import 'dart:io';

import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zstd_decoder.dart';
import '../util/archive_exception.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
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

  int _total = 0;
  final _links = <({String linkPath, String relative, String target})>[];

  EntryWriter(this.outputPath,
      {this.bufferSize, this.maxSize, bool setPermissions = false})
      : setPermissions = setPermissions && posix.isPosixSupported() {
    Directory(outputPath).createSync(recursive: true);
  }

  /// Writes [file], returning where, or null if it was refused for pointing
  /// outside [outputPath]. A link is only recorded here; see [finish].
  String? write(ArchiveFile file) {
    final relative = path.normalize(file.name);
    final filePath = path.join(outputPath, relative);
    if (!_isWithin(outputPath, filePath)) {
      return null;
    }

    if (file.isSymbolicLink) {
      final target = path.normalize(file.symbolicLink!);
      final linkDir = path.dirname(filePath);
      if (path.isAbsolute(target) ||
          !_isWithin(outputPath, path.join(linkDir, target))) {
        return null;
      }
      _links.add((linkPath: filePath, relative: relative, target: target));
      return filePath;
    }

    if (file.isDirectory) {
      Directory(filePath).createSync(recursive: true);
      return filePath;
    }

    _total += file.size;
    final maxSize = this.maxSize;
    if (maxSize != null && _total > maxSize) {
      throw ArchiveException(
          'Extracting the archive would write more than $maxSize bytes');
    }

    // The buffer is allocated per file, so for a small file it is cut down
    // to the file's size rather than the full default. With 20,000 files of
    // 2 KB that is a quarter of the extraction time.
    final size = file.size;
    final defaultSize = bufferSize ?? OutputFileStream.kDefaultBufferSize;
    final output = OutputFileStream(filePath,
        bufferSize: size < defaultSize ? size : defaultSize);
    try {
      file.writeContent(output);
    } catch (_) {
      // A partial file would pass for the whole of it.
      output.closeSync();
      File(filePath).deleteSync();
      rethrow;
    }
    output.closeSync();
    if (setPermissions) {
      posix.chmod(filePath, file.unixPermissions.toRadixString(8));
    }
    return filePath;
  }

  /// Creates the links that [write] recorded.
  ///
  /// A link is refused if its own path, or its target short of the last
  /// part, runs through a link: the checks in [write] are made on the path
  /// alone, which is only what the file system does when no part of it is a
  /// link. Each is checked again once all are made, since a link made later
  /// can sit in the path of one made earlier.
  void finish() {
    final made = <({String linkPath, String relative, String target})>[];
    for (final link in _links) {
      if (_runsThroughLink(link) ||
          FileSystemEntity.typeSync(link.linkPath, followLinks: false) !=
              FileSystemEntityType.notFound) {
        continue;
      }
      Link(link.linkPath).createSync(link.target, recursive: true);
      made.add(link);
    }
    for (final link in made) {
      if (_runsThroughLink(link)) {
        Link(link.linkPath).deleteSync();
      }
    }
    _links.clear();
  }

  bool _runsThroughLink(
      ({String linkPath, String relative, String target}) link) {
    final parent = path.dirname(link.relative);
    final targetParts = path.split(link.target);
    return _anyIsLink(outputPath, parent == '.' ? [] : path.split(parent)) ||
        _anyIsLink(path.dirname(link.linkPath),
            targetParts.sublist(0, targetParts.length - 1));
  }

  // Whether any of the paths [from] + [parts][0..i] is a link.
  static bool _anyIsLink(String from, List<String> parts) {
    var current = from;
    for (final part in parts) {
      current = path.join(current, part);
      if (FileSystemEntity.isLinkSync(current)) {
        return true;
      }
    }
    return false;
  }

  static bool _isWithin(String outputDir, String filePath) =>
      path.isWithin(path.canonicalize(outputDir), path.canonicalize(filePath));
}

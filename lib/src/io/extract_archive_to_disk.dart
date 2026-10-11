import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip/zip_file.dart';
import '../codecs/zip_decoder.dart';
import '../codecs/zstd_decoder.dart';
import '../util/_link_target.dart';
import '../util/archive_exception.dart';
import '../util/codecs_recognizer.dart';
import '../util/decode_guard.dart';
import '../util/input_file_stream.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
import '../util/output_stream.dart';
import 'posix.dart' as posix;

// Adds [size] to what has been written so far, refusing to go past [maxSize].
int _addToTotal(int total, int size, int? maxSize) {
  total += size;
  if (maxSize != null && total > maxSize) {
    throw ArchiveException(
        'Extracting the archive would write more than $maxSize bytes');
  }
  return total;
}

// Ensure filePath is contained in the outputDir folder, to make sure archives
// aren't trying to write to some system path.
bool _isWithinOutputPath(String? realOut, String filePath) {
  final file = _realPath(filePath, followDangling: true);
  return realOut != null && file != null && path.isWithin(realOut, file);
}

Future<bool> _isWithinOutputPathAsync(String? realOut, String filePath) async {
  final file = await _realPathAsync(filePath, followDangling: true);
  return realOut != null && file != null && path.isWithin(realOut, file);
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

Future<String?> _realPathAsync(String filePath,
    {bool followDangling = false, int depth = 0}) async {
  var existing = path.absolute(filePath);
  final rest = <String>[];
  while (await FileSystemEntity.type(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    if (path.dirname(existing) == existing) {
      return path.canonicalize(filePath);
    }
    rest.insert(0, path.basename(existing));
    existing = path.dirname(existing);
  }
  try {
    return path.joinAll([await File(existing).resolveSymbolicLinks(), ...rest]);
  } on FileSystemException {
    if (!followDangling ||
        depth >= 40 ||
        await FileSystemEntity.type(existing, followLinks: false) !=
            FileSystemEntityType.link) {
      return null;
    }
    final target = await Link(existing).target();
    return _realPathAsync(
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
    outputPath, path.normalize(name.replaceFirst(RegExp(r'^[/\\]+'), '')));

bool _isValidSymLink(
    String outputPath, String? realOut, ArchiveFile file, bool allowAbsolute) {
  final filePath = path.dirname(_entryPath(outputPath, file.name));
  final linkPath = linkTarget(file);
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return allowAbsolute;
  }
  final realPath = _realPath(filePath);
  if (realPath == null ||
      !_isWithinOutputPath(realOut, path.join(realPath, linkPath))) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  return true;
}

Future<bool> _isValidSymLinkAsync(String outputPath, String? realOut,
    ArchiveFile file, bool allowAbsolute) async {
  final filePath = path.dirname(_entryPath(outputPath, file.name));
  final linkPath = linkTarget(file);
  if (path.isAbsolute(linkPath)) {
    return allowAbsolute;
  }
  final realPath = await _realPathAsync(filePath);
  return realPath != null &&
      await _isWithinOutputPathAsync(realOut, path.join(realPath, linkPath));
}

/// Windows needs \ in a relative link target, and normalizing the text would
/// change where a link through another link points
String _linkText(ArchiveFile file) {
  final text = linkTarget(file);
  return Platform.isWindows ? text.replaceAll('/', r'\') : text;
}

/// A later archive entry could replace a parent directory with a symlink.
/// Like GNU tar, we defer creating and validating these links until the
/// entire tree is extracted
bool _delaysLink(ArchiveFile file) {
  final target = linkTarget(file);
  return path.isAbsolute(target) || path.split(target).contains('..');
}

void _delayLink(
    Map<String, ArchiveFile> delayed, String filePath, ArchiveFile file) {
  _clearPath(filePath);
  Directory(path.dirname(filePath)).createSync(recursive: true);
  delayed.remove(filePath);
  delayed[filePath] = file;
}

Future<void> _delayLinkAsync(
    Map<String, ArchiveFile> delayed, String filePath, ArchiveFile file) async {
  await _clearPathAsync(filePath);
  await Directory(path.dirname(filePath)).create(recursive: true);
  delayed.remove(filePath);
  delayed[filePath] = file;
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
  for (final MapEntry(key: filePath, value: file) in created) {
    if (!_isValidSymLink(outputPath, realOut, file, allowAbsoluteSymlinks)) {
      Link(filePath).deleteSync();
    }
  }
}

Future<void> _createDelayedLinks(Map<String, ArchiveFile> delayed,
    String outputPath, String? realOut, bool allowAbsoluteSymlinks) async {
  final created = <MapEntry<String, ArchiveFile>>[];
  for (final entry in delayed.entries.toList().reversed) {
    if (await FileSystemEntity.type(entry.key, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await Link(entry.key).create(_linkText(entry.value), recursive: true);
      created.add(entry);
    }
  }
  for (final MapEntry(key: filePath, value: file) in created) {
    if (!await _isValidSymLinkAsync(
        outputPath, realOut, file, allowAbsoluteSymlinks)) {
      await Link(filePath).delete();
    }
  }
}

/// Caching is needed to reduce speed by 50%
class _OutputPaths {
  final String? realOut;
  final _dirs = <String, String?>{};

  _OutputPaths(this.realOut);

  bool isEntryWithin(String filePath) {
    final dir = path.dirname(filePath);
    if (!_dirs.containsKey(dir)) {
      _dirs[dir] = _realPath(dir);
    }
    return _within(_dirs[dir], filePath);
  }

  Future<bool> isEntryWithinAsync(String filePath) async {
    final dir = path.dirname(filePath);
    if (!_dirs.containsKey(dir)) {
      _dirs[dir] = await _realPathAsync(dir);
    }
    return _within(_dirs[dir], filePath);
  }

  bool _within(String? dir, String filePath) =>
      realOut != null &&
      dir != null &&
      path.isWithin(realOut!, path.join(dir, path.basename(filePath)));

  void linked() => _dirs.clear();

  void cleared(bool link) {
    if (link) {
      _dirs.clear();
    }
  }
}

Future<bool> _clearPathAsync(String filePath) async {
  final type = await FileSystemEntity.type(filePath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    await Link(filePath).delete();
    return true;
  } else if (type == FileSystemEntityType.file) {
    await File(filePath).delete();
  }
  return false;
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

Future<void> _createDirectoryAsync(String filePath) async {
  try {
    await Directory(filePath).create(recursive: true);
  } on FileSystemException {
    if (await FileSystemEntity.type(filePath, followLinks: false) !=
        FileSystemEntityType.file) {
      rethrow;
    }
    await File(filePath).delete();
    await Directory(filePath).create(recursive: true);
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

void _prepareOutDir(String outDirPath) {
  final outDir = Directory(outDirPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
}

String? _prepareArchiveFilePath(ArchiveFile archiveFile, String outputPath,
    String? realOut, bool allowAbsoluteSymlinks, _OutputPaths paths) {
  final filePath = _entryPath(outputPath, archiveFile.name);

  if (!paths.isEntryWithin(filePath)) {
    return null;
  }

  if (archiveFile.isSymbolicLink) {
    if (!_isValidSymLink(
        outputPath, realOut, archiveFile, allowAbsoluteSymlinks)) {
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

void _extractArchiveEntryToDiskSync(
  ArchiveFile entry,
  String filePath,
  _OutputPaths paths, {
  int? bufferSize,
  bool throwOnError = false,
}) {
  if (entry.isSymbolicLink) {
    _clearPath(filePath);
    final link = Link(filePath);
    link.createSync(_linkText(entry), recursive: true);
    paths.linked();
  } else {
    if (entry.isFile) {
      paths.cleared(_clearPath(filePath));
      bufferSize ??= OutputFileStream.kDefaultBufferSize;
      final output = OutputFileStream(filePath,
          bufferSize: entry.size < bufferSize ? entry.size : bufferSize);
      try {
        _writeStrict(entry, output);
      } catch (err) {
        if (err is ArchivePasswordException) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        if (!isDecodeDataError(err)) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        if (throwOnError) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        //
        output.closeSync();
        try {
          File(filePath).deleteSync();
        } catch (_) {}
        return;
      }
      output.closeSync();
    } else {
      _createDirectory(filePath);
    }
  }
}

/// Writes the entries of [archive] into [outputPath]
///
/// With [throwOnError] a damaged entry throws `ArchiveException`, without it
/// the entry is skipped and leaves no file
///
/// {@macro archive.extract.cut_tar}
///
/// {@macro archive.extract.allow_absolute_symlinks}
///
/// {@macro archive.extract.max_size}
void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
  bool throwOnError = false,
  bool allowAbsoluteSymlinks = false,
  int? maxSize,
}) {
  _prepareOutDir(outputPath);
  final realOut = _realPath(outputPath);
  final paths = _OutputPaths(realOut);
  final delayed = <String, ArchiveFile>{};
  var total = 0;
  for (final entry in archive) {
    final filePath = _prepareArchiveFilePath(
        entry, outputPath, realOut, allowAbsoluteSymlinks, paths);
    if (filePath != null) {
      if (entry.isSymbolicLink && _delaysLink(entry)) {
        _delayLink(delayed, filePath, entry);
        paths.cleared(true);
        continue;
      }
      if (entry.isFile && !entry.isSymbolicLink) {
        total = _addToTotal(total, entry.size, maxSize);
      }
      _extractArchiveEntryToDiskSync(entry, filePath, paths,
          bufferSize: bufferSize, throwOnError: throwOnError);
    }
  }
  _createDelayedLinksSync(delayed, outputPath, realOut, allowAbsoluteSymlinks);
}

/// Writes the entries of [archive] into [outputPath]
///
/// With [throwOnError] a damaged entry throws `ArchiveException`, without it
/// the entry is skipped and leaves no file
///
/// {@macro archive.extract.cut_tar}
///
/// {@macro archive.extract.allow_absolute_symlinks}
///
/// {@macro archive.extract.max_size}
Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {int? bufferSize,
    bool throwOnError = false,
    bool allowAbsoluteSymlinks = false,
    int? maxSize}) async {
  final outDir = Directory(outputPath);
  if (!await outDir.exists()) {
    await outDir.create(recursive: true);
  }
  final realOut = await _realPathAsync(outputPath);
  final paths = _OutputPaths(realOut);
  final delayed = <String, ArchiveFile>{};
  var total = 0;

  for (final entry in archive) {
    final filePath = _entryPath(outputPath, entry.name);

    if (!await paths.isEntryWithinAsync(filePath)) {
      continue;
    }

    if (entry.isSymbolicLink) {
      if (!await _isValidSymLinkAsync(
          outputPath, realOut, entry, allowAbsoluteSymlinks)) {
        continue;
      }
      if (_delaysLink(entry)) {
        await _delayLinkAsync(delayed, filePath, entry);
        paths.cleared(true);
        continue;
      }

      await _clearPathAsync(filePath);
      final link = Link(filePath);
      await link.create(_linkText(entry), recursive: true);
      paths.linked();
      continue;
    }

    if (entry.isDirectory) {
      await _createDirectoryAsync(filePath);
      continue;
    }

    ArchiveFile file = entry;
    total = _addToTotal(total, file.size, maxSize);

    bufferSize ??= OutputFileStream.kDefaultBufferSize;
    final fileSize = file.size;
    final fileBufferSize = fileSize < bufferSize ? fileSize : bufferSize;
    paths.cleared(await _clearPathAsync(filePath));
    final output = OutputFileStream(filePath, bufferSize: fileBufferSize);
    try {
      _writeStrict(file, output);
    } catch (err) {
      if (err is ArchivePasswordException) {
        await output.close();
        try {
          await File(filePath).delete();
        } catch (_) {}
        rethrow;
      }
      if (!isDecodeDataError(err)) {
        await output.close();
        try {
          await File(filePath).delete();
        } catch (_) {}
        rethrow;
      }
      if (throwOnError) {
        await output.close();
        try {
          await File(filePath).delete();
        } catch (_) {}
        rethrow;
      }
      //
      await output.close();
      try {
        await File(filePath).delete();
      } catch (_) {}
      continue;
    }
    await output.close();
  }
  await _createDelayedLinks(
      delayed, outputPath, realOut, allowAbsoluteSymlinks);
}

// a utility function to get the extension of the input file.
String getInputExtension(String inputPath) {
  final lowerPath = inputPath.toLowerCase();
  if (lowerPath.endsWith('.tar.gz')) {
    return '.tar.gz';
  } else if (lowerPath.endsWith('.tar.bz2')) {
    return '.tar.bz2';
  } else if (lowerPath.endsWith('.tar.xz')) {
    return '.tar.xz';
  } else if (lowerPath.endsWith('.tar.zst')) {
    return '.tar.zst';
  }
  return path.extension(lowerPath);
}

/// Extracts the archive at [inputPath] into [outputPath]
///
/// {@macro archive.verify_throw_on_error}
///
/// If neither option is specified, damaged or incomplete entries are skipped,
/// and only complete ones are extracted
///
/// {@macro archive.extract.allow_absolute_symlinks}
///
/// {@macro archive.extract.max_size}
Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password,
    int? bufferSize,
    ArchiveCallback? callback,
    bool verify = false,
    bool throwOnError = false,
    bool allowAbsoluteSymlinks = false,
    int? maxSize}) async {
  final strict = verify || throwOnError;
  final archivePath = inputPath;

  var posixSupported = posix.isPosixSupported();

  const String extensionMsg =
      '.tar.gz, .tgz, .tar.bz2, .tbz, .tar.xz, .txz, .tar.zst, .tzst, .tar '
      'or .zip';

  // get the extension of the input file with up to 2 components
  // e.g. for file.tar.gz, it will return '.tar.gz'
  final archiveExt = getInputExtension(archivePath);

  // Check header to avoid attempts for all formats
  RandomAccessFile? raf;
  Uint8List headerBytes;
  try {
    raf = await File(inputPath).open(mode: FileMode.read);
    headerBytes = await raf.read(CodecsRecognizer.headerBytes);
  } catch (_) {
    headerBytes = Uint8List(0);
  } finally {
    try {
      await raf?.close();
    } catch (_) {
      /* Do nothing */
    }
  }

  ArchiveFormat recognized = CodecsRecognizer.recognize(headerBytes);
  if (recognized == ArchiveFormat.unknown) {
    for (final ArchiveFormat format in ArchiveFormat.values) {
      final ArchiveExtension? aExt = CodecsRecognizer.extensionOf(format);
      if (aExt == null) continue;

      if (archiveExt == '.${aExt.defaultName}' ||
          (aExt.tar != null && archiveExt == '.${aExt.tar}') ||
          (aExt.tarShort != null && archiveExt == '.${aExt.tarShort}')) {
        recognized = format;
        break;
      }
    }
  }

  if (recognized == ArchiveFormat.unknown) {
    throw ArgumentError.value(
      inputPath,
      'inputPath',
      'No file extension detected, must end with $extensionMsg',
    );
  }

  // Each of these throws where the archive ran out part way through.
  // If neither `verify` nor `throwOnError` is set, exceptions are suppressed,
  // and only complete tar entries are extracted
  final InputStream Function(InputStream input)? lazy = switch (recognized) {
    ArchiveFormat.gzip => (input) =>
        GZipDecoder().decodeLazy(input, verify: verify),
    ArchiveFormat.bzip2 => (input) =>
        BZip2Decoder().decodeLazy(input, verify: verify),
    ArchiveFormat.xz => (input) =>
        XZDecoder().decodeLazy(input, verify: verify),
    ArchiveFormat.zstd => (input) =>
        ZstdDecoder().decodeLazy(input, verify: verify),
    _ => null,
  };

  InputStream? toClose;
  try {
    if (lazy != null || recognized == ArchiveFormat.tar) {
      final input = InputFileStream(inputPath);
      toClose = input;
      _prepareOutDir(outputPath);
      final realOut = _realPath(outputPath);
      final paths = _OutputPaths(realOut);
      final delayed = <String, ArchiveFile>{};
      var total = 0;
      Object? callbackError;
      Object? limitError;
      void write(ArchiveFile file) {
        if (callback != null) {
          try {
            callback(file);
          } catch (error) {
            callbackError = error;
            rethrow;
          }
        }
        final filePath = _prepareArchiveFilePath(
            file, outputPath, realOut, allowAbsoluteSymlinks, paths);
        if (filePath == null) {
          return;
        }
        if (file.isSymbolicLink && _delaysLink(file)) {
          _delayLink(delayed, filePath, file);
          paths.cleared(true);
          return;
        }
        final isFile = file.isFile && !file.isSymbolicLink;
        if (isFile) {
          try {
            total = _addToTotal(total, file.size, maxSize);
          } catch (error) {
            limitError = error;
            rethrow;
          }
        }
        _extractArchiveEntryToDiskSync(file, filePath, paths,
            bufferSize: bufferSize, throwOnError: strict);
        final written = File(filePath);
        if (!isFile || !written.existsSync()) {
          return;
        }
        // The length of a lazily decoded tar is not known up front, so an
        // entry cut short by the end of the data is found here
        if (written.lengthSync() < file.size) {
          written.deleteSync();
          throw ArchiveException('Unexpected end of tar data in ${file.name}');
        }
        if (posixSupported) {
          posix.chmod(filePath, file.unixPermissions.toRadixString(8));
        }
      }

      // tar has no magic bytes. The file under the gzip or zstd might not be a
      // tar at all. The header checksum rejects it. Without the check a
      // .sql.gz is extracted as tar entries
      // Truncated tar entry is deleted once it is written. bsdtar and python
      // tarfile leave partial file on disk, but they report error too
      try {
        final tar = lazy?.call(input) ?? input;
        TarDecoder().decodeStream(tar,
            verify: true, keepEntries: false, callback: write);
        // The tar ends before the compressed data does, and the decoders only
        // find a cut or damaged end once they reach it
        if (strict && lazy != null) {
          while (!tar.isEOS) {
            tar.readBytes(1 << 16).toUint8List();
          }
        }
      } catch (error) {
        if (strict ||
            !isDecodeDataError(error) ||
            identical(error, callbackError) ||
            identical(error, limitError)) {
          rethrow;
        }
      }
      _createDelayedLinksSync(
          delayed, outputPath, realOut, allowAbsoluteSymlinks);
      return;
    }

    Archive archive;
    if (recognized == ArchiveFormat.zip) {
      final input = InputFileStream(archivePath);
      toClose = input;
      archive = ZipDecoder().decodeStream(input,
          verify: verify,
          throwOnError: strict,
          password: password,
          callback: callback);
    } else {
      throw ArgumentError.value(
          inputPath, 'inputPath', 'Must end $extensionMsg');
    }

    final realOut = await _realPathAsync(outputPath);
    final paths = _OutputPaths(realOut);
    final delayed = <String, ArchiveFile>{};
    var total = 0;
    for (final file in archive) {
      final filePath = _entryPath(outputPath, file.name);
      if (!await paths.isEntryWithinAsync(filePath)) {
        continue;
      }

      if (file.isSymbolicLink) {
        if (!await _isValidSymLinkAsync(
            outputPath, realOut, file, allowAbsoluteSymlinks)) {
          continue;
        }
        if (_delaysLink(file)) {
          await _delayLinkAsync(delayed, filePath, file);
          paths.cleared(true);
          continue;
        }
      }

      if (file.isDirectory && !file.isSymbolicLink) {
        await _createDirectoryAsync(filePath);
        continue;
      }

      if (file.isSymbolicLink) {
        await _clearPathAsync(filePath);
        final link = Link(filePath);
        await link.create(_linkText(file), recursive: true);
        paths.linked();
      } else if (file.isFile) {
        total = _addToTotal(total, file.size, maxSize);
        paths.cleared(await _clearPathAsync(filePath));
        final size = bufferSize ?? OutputFileStream.kDefaultBufferSize;
        final output = OutputFileStream(filePath,
            bufferSize: file.size < size ? file.size : size);
        try {
          _writeStrict(file, output);
        } catch (error) {
          // A partial file from a failed entry looked extracted, so we delete
          // it
          try {
            await output.close();
          } catch (_) {}
          // Windows delete throws on an open file, so we ignore the error
          try {
            await File(filePath).delete();
          } catch (_) {}
          if (error is ArchivePasswordException) {
            rethrow;
          }
          if (!isDecodeDataError(error)) {
            rethrow;
          }
          if (strict) {
            rethrow;
          }
          continue;
        }
        if (posixSupported) {
          posix.chmod(filePath, file.unixPermissions.toRadixString(8));
        }

        await output.close();
      }
    }
    await _createDelayedLinks(
        delayed, outputPath, realOut, allowAbsoluteSymlinks);

    await archive.clear();
  } finally {
    // The input handle is scoped to this call. If an error occurs midway, it
    // is closed here
    await toClose?.close();
  }
}

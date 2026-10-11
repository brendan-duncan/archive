import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/zip_decoder.dart';
import '../util/input_file_stream.dart';
import '_entry_writer.dart';

/// Writes the entries of [archive] into the directory [outputPath].
///
/// An entry whose path or link target would land outside [outputPath] is
/// skipped. Symbolic links are created after every other entry, and one that
/// would lead through another link is skipped too.
///
/// [maxSize] limits the total size of the files written. An entry that would
/// take it past that throws an [ArchiveException] before it is written. A zip
/// entry is never decoded past the size the archive gives for it.
///
/// An entry whose content fails to decode throws, and its partial file is
/// removed.
void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
  int? maxSize,
}) {
  final writer =
      EntryWriter(outputPath, bufferSize: bufferSize, maxSize: maxSize);
  for (final entry in archive) {
    writer.write(entry);
  }
  writer.finish();
}

/// Writes the entries of [archive] into the directory [outputPath].
///
/// This is [extractArchiveToDiskSync], with the same arguments.
Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {int? bufferSize, int? maxSize}) async {
  extractArchiveToDiskSync(archive, outputPath,
      bufferSize: bufferSize, maxSize: maxSize);
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

const _tarExtensions = {
  '.tar.gz',
  '.tgz',
  '.tar.bz2',
  '.tbz',
  '.tar.zst',
  '.tzst',
  '.tar.xz',
  '.txz',
  '.tar',
};

/// Extracts the archive at [inputPath] into the directory [outputPath].
///
/// The archive may be a `.zip`, `.tar`, or a tar compressed as `.tar.gz`,
/// `.tgz`, `.tar.bz2`, `.tbz`, `.tar.xz`, `.txz`, `.tar.zst` or `.tzst`.
///
/// A compressed tar is decompressed as it is read and every entry written out
/// as it is reached, so no more than a few megabytes of it are in memory at a
/// time and no temp file is needed.
///
/// [callback] is called for each entry once it has been written. For a
/// compressed tar the entry's content has gone by then and cannot be read
/// from the entry; it is in the file on disk.
///
/// [bufferSize] is the size of the write buffer for each extracted file, and
/// [password] decrypts an encrypted zip.
///
/// [maxSize] limits the total size of the files written, which a small
/// compressed archive can otherwise make as large as it likes. An entry that
/// would take it past that throws an [ArchiveException] before it is
/// written. A zip entry is never decoded past the size the archive gives for
/// it.
///
/// Entries are kept inside [outputPath] as [extractArchiveToDiskSync]
/// describes, and an entry whose content fails to decode throws.
Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password,
    int? bufferSize,
    ArchiveCallback? callback,
    int? maxSize}) async {
  const String extensionMsg =
      '.tar.gz, .tgz, .tar.bz2, .tbz, .tar.xz, .txz, .tar.zst, .tzst, .tar '
      'or .zip';

  // get the extension of the input file with up to 2 components
  // e.g. for file.tar.gz, it will return '.tar.gz'
  final archiveExt = getInputExtension(inputPath);
  if (archiveExt.isEmpty) {
    throw ArgumentError.value(
      inputPath,
      'inputPath',
      'No file extension detected, must end with $extensionMsg',
    );
  }
  if (archiveExt != '.zip' && !_tarExtensions.contains(archiveExt)) {
    throw ArgumentError.value(inputPath, 'inputPath', 'Must end $extensionMsg');
  }

  final writer = EntryWriter(outputPath,
      bufferSize: bufferSize, maxSize: maxSize, setPermissions: true);
  final file = InputFileStream(inputPath);
  try {
    if (archiveExt == '.zip') {
      final archive = ZipDecoder()
          .decodeStream(file, password: password, callback: callback);
      for (final entry in archive) {
        writer.write(entry);
      }
      await archive.clear();
    } else {
      final input = tarStreamFor(archiveExt, file)!;
      // Each entry is written as the decoder reaches it, which is the only
      // time its content is at hand when the tar is being decompressed on the
      // way in.
      try {
        TarDecoder().decodeStream(input, keepEntries: false, callback: (entry) {
          writer.write(entry);
          callback?.call(entry);
        });
      } finally {
        await input.close();
      }
    }
    writer.finish();
  } finally {
    await file.close();
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/tar/tar_file.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip_decoder.dart';
import '../codecs/zstd_decoder.dart';
import '../util/archive_exception.dart';
import '../util/codecs_recognizer.dart';
import '../util/decode_guard.dart';
import '../util/input_file_stream.dart';
import '../util/input_stream.dart';
import '_entry_writer.dart';

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
  final writer = EntryWriter(outputPath,
      bufferSize: bufferSize,
      maxSize: maxSize,
      throwOnError: throwOnError,
      allowAbsoluteSymlinks: allowAbsoluteSymlinks);
  for (final entry in archive) {
    writer.write(entry);
  }
  writer.finish();
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
  extractArchiveToDiskSync(archive, outputPath,
      bufferSize: bufferSize,
      throwOnError: throwOnError,
      allowAbsoluteSymlinks: allowAbsoluteSymlinks,
      maxSize: maxSize);
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
/// [callback] is called for each entry once it has been written. For a
/// compressed tar the entry's content has gone by then and cannot be read
/// from the entry; it is in the file on disk.
///
/// {@macro archive.extract.allow_absolute_symlinks}
///
/// {@macro archive.extract.max_size}
Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password,
    int? bufferSize,
    ArchiveCallback? callback,
    bool verify = false,
    bool? throwOnError,
    bool allowAbsoluteSymlinks = false,
    int? maxSize}) async {
  final strict = throwOnError ?? verify;
  final archivePath = inputPath;

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
      final writer = EntryWriter(outputPath,
          bufferSize: bufferSize,
          maxSize: maxSize,
          setPermissions: true,
          throwOnError: strict,
          allowAbsoluteSymlinks: allowAbsoluteSymlinks);
      Object? callbackError;

      void write(ArchiveFile file) {
        writer.write(file);
        if (callback != null) {
          try {
            callback(file);
          } catch (error) {
            callbackError = error;
            rethrow;
          }
        }
      }

      // tar has no magic bytes. The file under the gzip or zstd might not be a
      // tar at all. The header checksum rejects it. Without the check a
      // .sql.gz is extracted as tar entries
      // Truncated tar entry is deleted once it is written. bsdtar and python
      // tarfile leave partial file on disk, but they report error too
      try {
        final tar = lazy?.call(input) ?? input;
        final first = tar.peekBytes(512).toUint8List();
        if (first.any((b) => b != 0) &&
            (first.length < 512 ||
                !tarHeaderChecksumMatches(first) ||
                !tarHeaderSizeIsNumber(first))) {
          throw ArgumentError.value(
              inputPath, 'inputPath', 'Is not a tar archive');
        }
        TarDecoder().decodeStream(tar,
            verify: true,
            throwOnError: true,
            keepEntries: false,
            callback: write);
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
            error is ArchiveLimitException ||
            identical(error, callbackError) ||
            identical(error, writer.limitError)) {
          rethrow;
        }
      }
      writer.finish();
      return;
    }

    Archive archive;
    if (recognized == ArchiveFormat.zip) {
      final input = InputFileStream(archivePath);
      toClose = input;
      archive = ZipDecoder().decodeStream(input,
          verify: verify, throwOnError: strict, password: password);
    } else {
      throw ArgumentError.value(
          inputPath, 'inputPath', 'Must end $extensionMsg');
    }

    final writer = EntryWriter(outputPath,
        bufferSize: bufferSize,
        maxSize: maxSize,
        setPermissions: true,
        throwOnError: strict,
        allowAbsoluteSymlinks: allowAbsoluteSymlinks);
    for (final file in archive) {
      writer.write(file);
      callback?.call(file);
    }
    writer.finish();

    await archive.clear();
  } finally {
    // The input handle is scoped to this call. If an error occurs midway, it
    // is closed here
    await toClose?.close();
  }
}

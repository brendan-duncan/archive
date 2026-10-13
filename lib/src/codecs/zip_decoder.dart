import 'dart:convert';
import 'dart:typed_data';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/byte_order.dart';
import '../util/decode_guard.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'zip/zip_directory.dart';

int _dosSeconds(int date, int time) =>
    DateTime(((date >> 9) & 0x7f) + 1980, (date >> 5) & 0x0f, date & 0x1f,
            (time >> 11) & 0x1f, (time >> 5) & 0x3f, (time << 1) & 0x3e)
        .millisecondsSinceEpoch ~/
    1000;

// DOS date and time are writer's local time, so Info-ZIP unzip and 7-Zip take
// modification time from UT field (0x5455) when entry has one
int? _utSeconds(Uint8List? extra) {
  if (extra == null) {
    return null;
  }
  final data = ByteData.sublistView(extra);
  var at = 0;
  while (at + 4 <= extra.length) {
    final id = data.getUint16(at, Endian.little);
    final size = data.getUint16(at + 2, Endian.little);
    if (id == 0x5455 && size >= 5 && at + 9 <= extra.length) {
      return extra[at + 4] & 1 != 0
          ? data.getUint32(at + 5, Endian.little)
          : null;
    }
    at += 4 + size;
  }
  return null;
}

/// Decode a zip formatted buffer into an [Archive] object.
class ZipDecoder {
  late ZipDirectory directory;
  final Encoding? filenameEncoding;

  ZipDecoder({this.filenameEncoding});

  /// Decodes [bytes] as a zip archive
  ///
  /// {@macro archive.decoder_callback}
  ///
  /// {@macro archive.archive_verify_throw_on_error}
  ///
  /// Wrong or missing password always throws `ArchivePasswordException`, and
  /// AES data that does not match its MAC always throws `ArchiveMacException`
  Archive decodeBytes(List<int> bytes,
          {bool verify = false,
          bool throwOnError = false,
          String? password,
          ArchiveCallback? callback}) =>
      decodeStream(InputMemoryStream(bytes),
          verify: verify,
          throwOnError: throwOnError,
          password: password,
          callback: callback);

  /// Decodes [input] of a zip archive
  ///
  /// {@macro archive.decoder_callback}
  ///
  /// {@macro archive.archive_verify_throw_on_error}
  ///
  /// Wrong or missing password always throws `ArchivePasswordException`, and
  /// AES data that does not match its MAC always throws `ArchiveMacException`
  Archive decodeStream(InputStream input,
      {bool verify = false,
      bool throwOnError = false,
      String? password,
      ArchiveCallback? callback}) {
    final archive = Archive();
    final held = input.byteOrder;
    input.byteOrder = ByteOrder.littleEndian;
    try {
      guardDecode('zip', verify, throwOnError, () {
        _decode(input, archive, verify, throwOnError, password, callback);
        return true;
      });
    } finally {
      input.byteOrder = held;
    }
    return archive;
  }

  void _decode(InputStream input, Archive archive, bool verify,
      bool throwOnError, String? password, ArchiveCallback? callback) {
    directory = ZipDirectory();
    directory.read(input,
        password: password,
        verify: verify || throwOnError,
        filenameEncoding: filenameEncoding);
    if ((verify || throwOnError) && directory.filePosition < 0) {
      throw ArchiveException('zip: end of central directory not found');
    }

    for (final zfh in directory.fileHeaders) {
      final zf = zfh.file!;

      // The attributes are stored in base 8
      final mode = zfh.externalFileAttributes;

      zf.verify = verify;
      zf.throwOnError = throwOnError;

      final entryMode = mode >> 16;

      var isDirectory = zf.filename.endsWith('/') ||
          zf.filename.endsWith('\\') ||
          (zfh.versionMadeBy >> 8 == 0 && mode & 0x10 != 0) ||
          (zfh.versionMadeBy >> 8 == 3 && entryMode & 0xf000 == 0x4000);

      final filename = zf.filename;

      // Last duplicate name wins, as in 3.x and TarDecoder, since reusing the
      // first entry kept its content but took CRC of the last one
      final entry = isDirectory
          ? ArchiveFile.directory(filename)
          : ArchiveFile.file(filename, zf.uncompressedSize, zf);
      entry.compression = zf.compressionMethod;

      archive.add(entry);

      // Zips from Windows leave the Unix mode at 0, and extractFileToDisk then
      // chmod'ed every file to 000, so such entries keep the default mode
      if (entryMode != 0) {
        entry.mode = entryMode;
      }

      // see https://github.com/brendan-duncan/archive/issues/21
      // UNIX systems has a creator version of 3 decimal at 1 byte offset
      if (zfh.versionMadeBy >> 8 == 3) {
        final fileType = entry.mode & 0xf000;
        if (fileType == 0xa000) {
          final f = ArchiveFile.file(filename, zf.uncompressedSize, zf);
          f.compression = zf.compressionMethod;
          final bytes = f.readBytes();
          if (bytes != null) {
            entry.symbolicLink =
                InputMemoryStream(bytes).readString(size: bytes.length);
          }
        }
      }

      entry
        ..crc32 = zf.hasCrc32 ? zf.crc32 : null
        ..lastModTime = _utSeconds(zf.header?.extraField) ??
            _utSeconds(zf.extraField) ??
            _dosSeconds(zf.lastModFileDate, zf.lastModFileTime)
        ..lastModDosTime = zf.lastModFileDate << 16 | zf.lastModFileTime;

      if (callback != null) {
        try {
          callback(entry);
        } catch (error, stackTrace) {
          throw CallbackFailure(error, stackTrace);
        }
      }
    }
  }
}

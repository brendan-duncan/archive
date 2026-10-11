import 'dart:convert';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'zip/zip_directory.dart';

/// Decode a zip formatted buffer into an [Archive] object.
class ZipDecoder {
  late ZipDirectory directory;

  Archive decodeBytes(List<int> bytes,
          {bool verify = false, String? password, ArchiveCallback? callback}) =>
      decodeStream(InputMemoryStream(bytes),
          verify: verify, password: password, callback: callback);

  Archive decodeStream(InputStream input,
      {bool verify = false, String? password, ArchiveCallback? callback}) {
    directory = ZipDirectory();
    try {
      directory.read(input, password: password);
    } on RangeError {
      // A length in a header that runs past the data it describes.
      throw ArchiveException('Invalid or truncated zip');
    }

    final archive = Archive();
    for (final zfh in directory.fileHeaders) {
      final zf = zfh.file!;

      // The attributes are stored in base 8
      final mode = zfh.externalFileAttributes;

      /*if (verify) {
        final stream = zf.getStream();
        final computedCrc = getCrc32(stream.toUint8List());
        if (computedCrc != zf.crc32) {
          throw ArchiveException('Invalid CRC for file in archive.');
        }
      }*/

      final entryMode = mode >> 16;

      var isDirectory = zf.filename.endsWith('/') || zf.filename.endsWith('\\');

      final filename = zf.filename;

      var entry = archive.find(filename);

      if (entry == null) {
        entry = isDirectory
            ? ArchiveFile.directory(filename)
            : ArchiveFile.file(filename, zf.uncompressedSize, zf);
        entry.compression = zf.compressionMethod;

        archive.add(entry);
      }

      entry.mode = entryMode;

      // see https://github.com/brendan-duncan/archive/issues/21
      // UNIX systems has a creator version of 3 decimal at 1 byte offset
      if (zfh.versionMadeBy >> 8 == 3) {
        final fileType = entry.mode & 0xf000;
        if (fileType == 0xa000) {
          final f = ArchiveFile.file(filename, zf.uncompressedSize, zf);
          f.compression = zf.compressionMethod;
          final bytes = f.readBytes();
          if (bytes != null) {
            entry.symbolicLink = utf8.decode(bytes);
          }
        }
      }

      entry
        ..crc32 = zf.crc32
        ..lastModTime = zf.lastModFileDate << 16 | zf.lastModFileTime;

      if (callback != null) {
        callback(entry);
      }
    }

    return archive;
  }
}

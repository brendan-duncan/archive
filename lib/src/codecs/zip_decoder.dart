import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../archive/archive.dart';
import '../archive/archive_directory.dart';
import '../archive/archive_entry.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/crc32.dart';
import '../util/input_stream.dart';
import '../util/input_memory_stream.dart';
import 'zip/zip_directory.dart';

/// Decode a zip formatted buffer into an [Archive] object.
class ZipDecoder {
  late ZipDirectory directory;

  Archive decode(Uint8List data,
          {bool verify = false, String? password, ArchiveCallback? callback}) =>
      decodeStream(InputMemoryStream(data),
          verify: verify, password: password, callback: callback);

  Archive decodeStream(InputStream input,
      {bool verify = false, String? password, ArchiveCallback? callback}) {
    directory = ZipDirectory();
    directory.read(input, password: password);

    final archive = Archive();
    for (final zfh in directory.fileHeaders) {
      final zf = zfh.file!;

      // The attributes are stored in base 8
      final mode = zfh.externalFileAttributes;

      if (verify) {
        final stream = zf.getStream();
        final computedCrc = getCrc32(stream.toUint8List());
        if (computedCrc != zf.crc32) {
          throw ArchiveException('Invalid CRC for file in archive.');
        }
      }

      final entryMode = mode >> 16;

      var isDirectory = false;
      if (zfh.versionMadeBy >> 8 == 3) {
        final fileType = entryMode & 0xf000;
        // No determination can be made so we assume it's a file.)
        if (fileType == 0x8000 || fileType == 0x0000) {
          isDirectory = false;
        } else {
          isDirectory = true;
        }
      } else {
        isDirectory = zf.filename.endsWith('/');
      }

      final dir = archive.getOrCreateDirectory(zf.filename);

      final pathTk = p.split(zf.filename);
      if (pathTk.last.isEmpty) {
        pathTk.removeLast();
      }
      final filename = pathTk.last;

      var entry = archive.find(filename);

      if (entry == null) {
        entry = isDirectory
            ? ArchiveDirectory(filename)
            : ArchiveFile.file(filename, zf.uncompressedSize, zf,
                compression: zf.compressionMethod);

        if (dir != null) {
          dir.add(entry);
        } else {
          archive.add(entry);
        }
      }

      entry.mode = entryMode;

      // see https://github.com/brendan-duncan/archive/issues/21
      // UNIX systems has a creator version of 3 decimal at 1 byte offset
      if (zfh.versionMadeBy >> 8 == 3) {
        final fileType = entry.mode & 0xf000;
        if (fileType == 0xa000) {
          final f = ArchiveFile.file(filename, zf.uncompressedSize, zf,
              compression: zf.compressionMethod);
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

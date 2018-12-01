import 'util/archive_exception.dart';
import 'util/crc32.dart';
import 'util/input_stream.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file_header.dart';
import 'zip/zip_file.dart';
import 'archive.dart';
import 'archive_file.dart';

/**
 * Decode a zip formatted buffer into an [Archive] object.
 */
class ZipDecoder {
  ZipDirectory directory;

  Archive decodeBytes(List<int> data, {bool verify: false, String password}) {
    return decodeBuffer(new InputStream(data), verify: verify, password: password);
  }

  Archive decodeBuffer(InputStream input, {bool verify: false, String password}) {
    directory = new ZipDirectory.read(input, password: password);
    Archive archive = new Archive();

    for (ZipFileHeader zfh in directory.fileHeaders) {
      ZipFile zf = zfh.file;

      // The attributes are stored in base 8
      final unixAttributes = zfh.externalFileAttributes >> 16;
      final unixPermissions = unixAttributes & 0x1FF;
      final compress = zf.compressionMethod != ZipFile.STORE;

      if (verify) {
        int computedCrc = getCrc32(zf.content);
        if (computedCrc != zf.crc32) {
          throw new ArchiveException('Invalid CRC for file in archive.');
        }
      }

      var content = zf.rawContent;
      var file = new ArchiveFile(zf.filename, zf.uncompressedSize,
          content, zf.compressionMethod);
      file.unixPermissions = unixPermissions;

      // see https://github.com/brendan-duncan/archive/issues/21
      // UNIX systems has a creator version of 3 decimal at 1 byte offset
      if (zfh.versionMadeBy >> 8 == 3) {
        final bool isDirectory = unixAttributes & 0x7000 == 0x4000;
        final bool isFile = unixAttributes & 0x3F000 == 0x8000;
        if (isFile || isDirectory) {
          file.isFile = isFile;
        }
      } else {
        file.isFile = !file.name.endsWith('/');
      }

      file.crc32 = zf.crc32;
      file.compress = compress;

      archive.addFile(file);
    }

    return archive;
  }
}

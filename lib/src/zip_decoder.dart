part of archive;

/**
 * Decode a zip formatted buffer into an [Archive] object.
 */
class ZipDecoder {
  ZipDirectory directory;

  Archive decodeBytes(List<int> data, {bool verify: false}) {
    return decodeBuffer(new InputStream(data), verify: verify);
  }

  Archive decodeBuffer(InputStream input, {bool verify: false}) {
    directory = new ZipDirectory.read(input);
    Archive archive = new Archive();

    for (ZipFileHeader zfh in directory.fileHeaders) {
      ZipFile zf = zfh.file;

      // The attributes are stored in base 8
      final unixAttributes = zfh.externalFileAttributes >> 16;
      final unixPermissions = unixAttributes & 0x1FF;
      final isDirectory = unixAttributes & 0x7000 == 0x4000;
      final isFile = unixAttributes & 0x3F000 == 0x8000;

      if (verify) {
        int computedCrc = getCrc32(zf.content);
        if (computedCrc != zf.crc32) {
          throw new ArchiveException('Invalid CRC for file in archive.');
        }
      }

      var content = zf._content != null ? zf._content : zf._rawContent;
      ArchiveFile file = new ArchiveFile(zf.filename, zf.uncompressedSize,
          content, zf.compressionMethod)
        ..unixPermissions = unixPermissions;

      if (isFile || isDirectory) {
        file.isFile = isFile;
      }

      file.crc32 = zf.crc32;

      archive.addFile(file);
    }

    return archive;
  }
}

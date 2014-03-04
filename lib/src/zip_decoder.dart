part of archive;

/**
 * Decode a zip formatted buffer into an [Archive] object.
 */
class ZipDecoder {
  ZipDirectory directory;

  Archive decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputStream(data), verify: verify);
  }

  Archive decodeBuffer(InputStream input, {bool verify: true}) {
    directory = new ZipDirectory.read(input);
    Archive archive = new Archive();

    for (ZipFileHeader zfh in directory.fileHeaders) {
      ZipFile zf = zfh.file;

      if (verify) {
        int computedCrc = getCrc32(zf.content);
        if (computedCrc != zf.crc32) {
          throw new ArchiveException('Invalid CRC for file in archive.');
        }
      }

      var content = zf._content != null ? zf._content : zf._rawContent;
      ArchiveFile file = new ArchiveFile(zf.filename, zf.uncompressedSize,
                                         content, zf.compressionMethod);
      file.crc32 = zf.crc32;

      archive.addFile(file);
    }

    return archive;
  }
}

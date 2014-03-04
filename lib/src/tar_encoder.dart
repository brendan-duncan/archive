part of archive;

/**
 * Encode an [Archive] object into a tar formatted buffer.
 */
class TarEncoder {
  List<int> encode(Archive archive) {
    OutputStream output = new OutputStream();

    for (ArchiveFile file in archive.files) {
      TarFile ts = new TarFile();
      ts.filename = file.name;
      ts.fileSize = file.size;
      ts.mode = file.mode;
      ts.ownerId = file.ownerId;
      ts.groupId = file.groupId;
      ts.lastModTime = file.lastModTime;
      ts._content = file.content;
      ts.write(output);
    }

    // At the end of the archive file there are two 512-byte blocks filled
    // with binary zeros as an end-of-file marker.
    Uint8List eof = new Uint8List(1024);
    output.writeBytes(eof);

    return output.getBytes();
  }
}

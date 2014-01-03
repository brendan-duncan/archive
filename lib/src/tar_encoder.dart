part of archive;

/**
 * Encode an [Archive] object into a tar formatted buffer.
 */
class TarEncoder {
  List<int> encode(Archive archive, {int byteOrder: LITTLE_ENDIAN}) {
    OutputBuffer output = new OutputBuffer(byteOrder: byteOrder);

    for (File file in archive.files) {
      TarFile ts = new TarFile();
      ts.filename = file.filename;
      ts.fileSize = file.fileSize;
      ts.mode = file.mode;
      ts.ownerId = file.ownerId;
      ts.groupId = file.groupId;
      ts.lastModTime = file.lastModTime;
      ts.content = file.content;
      ts.write(output);
    }

    // At the end of the archive file there are two 512-byte blocks filled
    // with binary zeros as an end-of-file marker.
    Data.Uint8List eof = new Data.Uint8List(1024);
    output.writeBytes(eof);

    return output.getBytes();
  }
}

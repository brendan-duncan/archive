part of archive;

/**
 * Encode an [Archive] object into a tar formatted buffer.
 */
class TarEncoder {
  List<int> encode(Archive archive) {
    OutputBuffer output = new OutputBuffer();

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

    // End the archive.
    output.writeBytes([0, 0]);

    return output.getBytes();
  }
}

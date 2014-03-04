part of archive;

/**
 * Decode a tar formatted buffer into an [Archive] object.
 */
class TarDecoder {
  List<TarFile> files = [];

  Archive decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputStream(data), verify: verify);
  }

  Archive decodeBuffer(InputStream input, {bool verify: true}) {
    Archive archive = new Archive();
    files.clear();

    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      if (input[0] == 0 && input[1] == 0) {
        break;
      }

      TarFile tf = new TarFile.read(input);
      files.add(tf);

      ArchiveFile file = new ArchiveFile(tf.filename, tf.fileSize, tf._rawContent);
      file.mode = tf.mode;
      file.ownerId = tf.ownerId;
      file.groupId = tf.groupId;
      file.lastModTime = tf.lastModTime;
      file.isFile = tf.isFile;

      archive.addFile(file);
    }

    return archive;
  }
}

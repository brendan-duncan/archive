part of archive;

/**
 * Decode a tar formatted buffer into an [Archive] object.
 */
class TarDecoder {
  List<TarFile> files = [];

  Archive decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputBuffer(data), verify: verify);
  }

  Archive decodeBuffer(InputBuffer input, {bool verify: true}) {
    Archive archive = new Archive();
    files.clear();

    while (!input.isEOF) {
      // End of archive when two consecutive 0's are found.
      if (input.buffer[input.position] == 0 &&
          input.buffer[input.position + 1] == 0) {
        break;
      }

      TarFile tf = new TarFile(input);
      files.add(tf);

      File file = new File(tf.filename, tf.fileSize, tf.content);
      file.mode = tf.mode;
      file.ownerId = tf.ownerId;
      file.groupId = tf.groupId;
      file.lastModTime = tf.lastModTime;

      archive.addFile(file);
    }

    return archive;
  }
}

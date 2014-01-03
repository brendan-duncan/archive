part of archive;

/**
 * Decode a tar formatted buffer into an [Archive] object.
 */
class TarDecoder {
  List<TarFile> files = [];

  // TODO: This should throw an exception on an error -
  Archive decode(List<int> data, {bool verify: true}) {
    Archive archive = new Archive();
    files.clear();
    InputBuffer input = new InputBuffer(data);
    while (!input.isEOF) {
      try {
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
      } catch (error) {
        break;
      }
    }

    return archive;
  }
}

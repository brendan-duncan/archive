part of archive;

class TarArchive {
  Archive decode(List<int> data) {
    Archive archive = new Archive();

    InputBuffer input = new InputBuffer(data);
    while (!input.isEOF) {
      try {
        // End of archive when two consecutive 0's are found.
        if (input.buffer[input.position] == 0 &&
            input.buffer[input.position + 1] == 0) {
          break;
        }

        TarFile file = new TarFile(input);

        File f = new File(file.filename, file.fileSize, file.content);
        f.mode = file.mode;
        f.ownerId = file.ownerId;
        f.groupId = file.groupId;

        archive.addFile(f);
      } catch (error) {
        break;
      }
    }

    return archive;
  }

  // Encode the files in the archive to the tar format.
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

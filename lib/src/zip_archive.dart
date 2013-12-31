part of archive;

class ZipArchive {
  ZipDirectory directory;

  Archive decode(List<int> data) {
    InputBuffer input = new InputBuffer(data);
    directory = new ZipDirectory(input);

    Archive archive = new Archive();

    for (ZipFileHeader zfh in directory.fileHeaders) {
      ZipFile zf = zfh.file;

      File file = new File(zf.filename, zf.uncompressedSize,
                           zf._content.buffer, File.DEFLATE);
      archive.addFile(file);
    }

    return archive;
  }

  List<int> encode(Archive archive) {
    OutputBuffer output = new OutputBuffer();

    return output.getBytes();
  }
}

part of dart_archive;

class ZipDirectory {
  // End of Central Directory Record
  static const int SIGNATURE = 0x06054b50;
  int filePosition = -1;
  int numberOfThisDisk = 0; // 2 bytes
  int diskWithTheStartOfTheCentralDirectory = 0; // 2 bytes
  int totalCentralDirectoryEntriesOnThisDisk = 0; // 2 bytes
  int totalCentralDirectoryEntries = 0; // 2 bytes
  int centralDirectorySize; // 4 bytes
  int centralDirectoryOffset; // 2 bytes
  String zipFileComment = ''; // 2 bytes, n bytes
  // Central Directory
  List<ZipFileHeader> fileHeaders = [];

  ZipDirectory([_ByteBuffer input]) {
    if (input != null) {
      // End Of
      filePosition = _findSignature(input);
      input.position = filePosition;
      int signature = input.readUint32();
      numberOfThisDisk = input.readUint16();
      diskWithTheStartOfTheCentralDirectory = input.readUint16();
      totalCentralDirectoryEntriesOnThisDisk = input.readUint16();
      totalCentralDirectoryEntries = input.readUint16();
      centralDirectorySize = input.readUint32();
      centralDirectoryOffset = input.readUint32();
      int len = input.readUint16();
      if (len > 0) {
        zipFileComment = new String.fromCharCodes(input.readBytes(len));
      }

      _ByteBuffer dirContent = input.subset(centralDirectoryOffset,
                                            centralDirectorySize);

      while (!dirContent.isEOF) {
        int fileSig = dirContent.readUint32();
        if (fileSig != ZipFileHeader.SIGNATURE) {
          break;
        }
        fileHeaders.add(new ZipFileHeader(dirContent, input));
      }
    }
  }

  int _findSignature(_ByteBuffer input) {
    const int maxLength = 65536;
    int pos = input.position;
    int length = input.length;

    // The directory and archive contents are written to the end of the zip
    // file.  We need to search from the end to find these structures,
    // starting with the 'End of central directory' record (EOCD).
    for (int ip = length - 4; ip > length - maxLength && ip > 0; --ip) {
      input.position = ip;
      int sig = input.readUint32();
      if (sig == SIGNATURE) {
        input.position = pos;
        return ip;
      }
    }

    throw new Exception('The Zip file seems to be corrupted.'
                        ' Could not find End of Central Directory Record'
                        ' location.');
  }
}

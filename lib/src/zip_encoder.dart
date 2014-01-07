part of archive;

/**
 * Encode an [Archive] object into a Zip formatted buffer.
 */
class ZipEncoder {
  List<int> encode(Archive archive, {int level: Deflate.BEST_SPEED}) {
    DateTime date = new DateTime.now();
    int t1 = ((date.minute & 0x7) << 5) | (date.second ~/ 2);
    int t2 = (date.hour << 3) | (date.minute >> 3);
    int t = ((t2 & 0xff) << 8) | (t1 & 0xff);

    int d1 = ((date.month + 1 & 0x7) << 5) | (date.day);
    int d2 = ((date.year - 1980 & 0x7f) << 1) | (date.month + 1 >> 3);
    int d = ((d2 & 0xff) << 8) | (d1 & 0xff);

    int localFileSize = 0;
    int centralDirectorySize = 0;
    int endOfCentralDirectorySize = 0;

    Map<File, Map> fileData = {};

    // Prepare the files, so we can know ahead of time how much space we need
    // for the output buffer.
    for (File file in archive.files) {
      fileData[file] = {};
      fileData[file]['time'] = t;
      fileData[file]['date'] = d;

      List<int> compressedData;
      int crc32;
      // If the file is already compressed, no sense in uncompressing it and
      // compressing it again, just pass along the already compressed data.
      if (file.compressionType == File.DEFLATE) {
        compressedData = file.rawContent;

        if (file.crc32 != null) {
          crc32 = file.crc32;
        } else {
          crc32 = getCrc32(file.content);
        }
      } else {
        // Otherwise we need to compress it now.
        crc32 = getCrc32(file.content);

        compressedData = new Deflate(file.content, level: level).getBytes();
      }

      localFileSize += 30 + file.filename.length + compressedData.length;

      centralDirectorySize += 46 + file.filename.length +
                             (file.comment != null ? file.comment.length : 0);

      fileData[file]['crc'] = crc32;
      fileData[file]['size'] = compressedData.length;
      fileData[file]['data'] = compressedData;
    }

    endOfCentralDirectorySize = 46 +
        (archive.comment != null ? archive.comment.length : 0);

    int outputSize = localFileSize + centralDirectorySize +
                     endOfCentralDirectorySize;

    OutputBuffer output = new OutputBuffer(size: outputSize);

    // Write Local File Headers
    for (File file in archive.files) {
      fileData[file]['pos'] = output.length;
      _writeFile(file, fileData, output);
    }

    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(archive, fileData, output);

    return output.getBytes();
  }

  void _writeFile(File file, Map fileData, OutputBuffer output) {
    // Local file header
    // Offset  Bytes Description[25]
    // 0   4 Local file header signature = 0x04034b50
    // 4   2 Version needed to extract (minimum)
    // 6   2 General purpose bit flag
    // 8   2 Compression method
    // 10  2 File last modification time
    // 12  2 File last modification date
    // 14  4 CRC-32
    // 18  4 Compressed size
    // 22  4 Uncompressed size
    // 26  2 File name length (n)
    // 28  2 Extra field length (m)
    // 30  n File name
    // 30+n  m Extra field
    output.writeUint32(ZipFile.SIGNATURE);

    int version = VERSION;
    int flags = 0;
    int compressionMethod = ZipFile.DEFLATE;
    int lastModFileTime = fileData[file]['time'];
    int lastModFileDate = fileData[file]['date'];
    int crc32 = fileData[file]['crc'];
    int compressedSize = fileData[file]['size'];
    int uncompressedSize = file.fileSize;
    String filename = file.filename;
    List<int> extra = [];

    List<int> compressedData = fileData[file]['data'];

    output.writeUint16(version);
    output.writeUint16(flags);
    output.writeUint16(compressionMethod);
    output.writeUint16(lastModFileTime);
    output.writeUint16(lastModFileDate);
    output.writeUint32(crc32);
    output.writeUint32(compressedSize);
    output.writeUint32(uncompressedSize);
    output.writeUint16(filename.length);
    output.writeUint16(extra.length);
    output.writeBytes(filename.codeUnits);
    output.writeBytes(extra);

    output.writeBytes(compressedData);

  }

  void _writeCentralDirectory(Archive archive, Map fileData,
                              OutputBuffer output) {
    int centralDirPosition = output.length;

    int version = VERSION;
    int os = OS_MSDOS;

    for (File file in archive.files) {
      // Central directory file header
      // Offset  Bytes Description[25]
      //  0  4 Central directory file header signature = 0x02014b50
      //  4  2 Version made by
      //  6  2 Version needed to extract (minimum)
      //  8  2 General purpose bit flag
      //  10  2 Compression method
      //  12  2 File last modification time
      //  14  2 File last modification date
      //  16  4 CRC-32
      //  20  4 Compressed size
      //  24  4 Uncompressed size
      //  28  2 File name length (n)
      //  30  2 Extra field length (m)
      //  32  2 File comment length (k)
      //  34  2 Disk number where file starts
      //  36  2 Internal file attributes
      //  38  4 External file attributes
      //  42  4 Relative offset of local file header.
      //  46  n File name
      //  46+n  m Extra field
      //  46+n+m  k File comment
      int versionMadeBy = (os << 8) | version;
      int versionNeededToExtract = version;
      int generalPurposeBitFlag = 0;
      int compressionMethod = ZipFile.DEFLATE;
      int lastModifiedFileTime = fileData[file]['time'];
      int lastModifiedFileDate = fileData[file]['date'];
      int crc32 = fileData[file]['crc'];
      int compressedSize = fileData[file]['size'];
      int uncompressedSize = file.fileSize;
      int diskNumberStart = 0;
      int internalFileAttributes = 0;
      int externalFileAttributes = 0;
      int localHeaderOffset = fileData[file]['pos'];
      String filename = file.filename;
      List<int> extraField = [];
      String fileComment = (file.comment == null ? '' : file.comment);

      output.writeUint32(ZipFileHeader.SIGNATURE);
      output.writeUint16(versionMadeBy);
      output.writeUint16(versionNeededToExtract);
      output.writeUint16(generalPurposeBitFlag);
      output.writeUint16(compressionMethod);
      output.writeUint16(lastModifiedFileTime);
      output.writeUint16(lastModifiedFileDate);
      output.writeUint32(crc32);
      output.writeUint32(compressedSize);
      output.writeUint32(uncompressedSize);
      output.writeUint16(filename.length);
      output.writeUint16(extraField.length);
      output.writeUint16(fileComment.length);
      output.writeUint16(diskNumberStart);
      output.writeUint16(internalFileAttributes);
      output.writeUint32(externalFileAttributes);
      output.writeUint32(localHeaderOffset);
      output.writeBytes(filename.codeUnits);
      output.writeBytes(extraField);
      output.writeBytes(fileComment.codeUnits);
    }

    // End of central directory record (EOCD)
    // Offset  Bytes Description[25]
    //  0  4 End of central directory signature = 0x06054b50
    //  4  2 Number of this disk
    //  6  2 Disk where central directory starts
    //  8  2 Number of central directory records on this disk
    // 10  2 Total number of central directory records
    // 12  4 Size of central directory (bytes)
    // 16  4 Offset of start of central directory, relative to start of archive
    // 20  2 Comment length (n)
    // 22  n Comment
    int numberOfThisDisk = 0;
    int diskWithTheStartOfTheCentralDirectory = 0;
    int totalCentralDirectoryEntriesOnThisDisk = archive.numberOfFiles();
    int totalCentralDirectoryEntries = archive.numberOfFiles();
    int centralDirectorySize = output.length - centralDirPosition;
    int centralDirectoryOffset = centralDirPosition;
    String comment = (archive.comment == null ? '' : archive.comment);

    output.writeUint32(ZipDirectory.SIGNATURE);
    output.writeUint16(numberOfThisDisk);
    output.writeUint16(diskWithTheStartOfTheCentralDirectory);
    output.writeUint16(totalCentralDirectoryEntriesOnThisDisk);
    output.writeUint16(totalCentralDirectoryEntries);
    output.writeUint32(centralDirectorySize);
    output.writeUint32(centralDirectoryOffset);
    output.writeUint16(comment.length);
    output.writeBytes(comment.codeUnits);
  }

  static const int VERSION = 20;

  // enum OS
  static const int OS_MSDOS = 0;
  static const int OS_UNIX = 3;
  static const int OS_MACINTOSH = 7;
}

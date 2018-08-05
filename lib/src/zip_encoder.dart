import 'util/crc32.dart';
import 'util/input_stream.dart';
import 'util/output_stream.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file.dart';
import 'zip/zip_file_header.dart';
import 'zlib/deflate.dart';
import 'archive.dart';
import 'archive_file.dart';

class _ZipFileData {
  String name;
  int time = 0;
  int date = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  InputStreamBase compressedData = null;
  bool compress = true;
  String comment = "";
  int position = 0;
}

class _ZipEncoderData {
  int level;
  int time;
  int date;
  int localFileSize = 0;
  int centralDirectorySize = 0;
  int endOfCentralDirectorySize = 0;
  List<_ZipFileData> files = [];

  _ZipEncoderData(this.level) {
    DateTime dateTime = new DateTime.now();
    int t1 = ((dateTime.minute & 0x7) << 5) | (dateTime.second ~/ 2);
    int t2 = (dateTime.hour << 3) | (dateTime.minute >> 3);
    time = ((t2 & 0xff) << 8) | (t1 & 0xff);

    int d1 = ((dateTime.month & 0x7) << 5) | dateTime.day;
    int d2 = (((dateTime.year - 1980) & 0x7f) << 1) | (dateTime.month >> 3);
    date = ((d2 & 0xff) << 8) | (d1 & 0xff);
  }
}


/**
 * Encode an [Archive] object into a Zip formatted buffer.
 */
class ZipEncoder {
  _ZipEncoderData _data;
  OutputStreamBase _output;

  List<int> encode(Archive archive, {int level: Deflate.BEST_SPEED,
                                     OutputStreamBase output}) {
    if (output == null) {
      output = new OutputStream();
    }

    startEncode(output, level: level);
    for (ArchiveFile file in archive.files) {
      addFile(file);
    }
    endEncode(comment: archive.comment);
    if (output is OutputStream) {
      return output.getBytes();
    }

    return null;
  }

  void startEncode(OutputStreamBase output, {int level: Deflate.BEST_SPEED}) {
    _data = new _ZipEncoderData(level);
    _output = output;
  }

  int getFileCrc32(ArchiveFile file) {
    if (file.content is InputStreamBase) {
      file.content.reset();
      var bytes = file.content.toUint8List();
      int crc32 = getCrc32(bytes);
      file.content.reset();
      return crc32;
    }
    return getCrc32(file.content);
  }

  void addFile(ArchiveFile file) {
    _ZipFileData fileData = new _ZipFileData();
    _data.files.add(fileData);

    fileData.name = file.name;
    fileData.time = _data.time;
    fileData.date = _data.date;

    InputStreamBase compressedData;
    int crc32;

    // If the user want's to store the file without compressing it,
    // make sure it's decompressed.
    if (!file.compress) {
      if (file.isCompressed) {
        file.decompress();
      }

      compressedData = (file.content is InputStreamBase) ?
                       file.content :
                       new InputStream(file.content);

      if (file.crc32 != null) {
        crc32 = file.crc32;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else if (file.isCompressed &&
        file.compressionType == ArchiveFile.DEFLATE) {
      // If the file is already compressed, no sense in uncompressing it and
      // compressing it again, just pass along the already compressed data.
      compressedData = file.rawContent;

      if (file.crc32 != null) {
        crc32 = file.crc32;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else {
      // Otherwise we need to compress it now.
      crc32 = getFileCrc32(file);

      var bytes = file.content;
      if (bytes is InputStreamBase) {
        bytes = bytes.toUint8List();
      }
      bytes = new Deflate(bytes, level: _data.level).getBytes();
      compressedData = new InputStream(bytes);
    }

    _data.localFileSize += 30 + file.name.length + compressedData.length;

    _data.centralDirectorySize += 46 + file.name.length +
        (file.comment != null ? file.comment.length : 0);

    fileData.crc32 = crc32;
    fileData.compressedSize = compressedData.length;
    fileData.compressedData = compressedData;
    fileData.uncompressedSize = file.size;
    fileData.compress = file.compress;
    fileData.comment = file.comment;
    fileData.position = _output.length;

    _writeFile(fileData, _output);

    fileData.compressedData = null;
  }

  void endEncode({String comment: ""}) {
    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(_data.files, comment, _output);
  }

  void _writeFile(_ZipFileData fileData, OutputStreamBase output) {
    var filename = fileData.name;

    output.writeUint32(ZipFile.SIGNATURE);

    int version = VERSION;
    int flags = 0;
    int compressionMethod = fileData.compress ? ZipFile.DEFLATE : ZipFile.STORE;
    int lastModFileTime = fileData.time;
    int lastModFileDate = fileData.date;
    int crc32 = fileData.crc32;
    int compressedSize = fileData.compressedSize;
    int uncompressedSize = fileData.uncompressedSize;
    List<int> extra = [];

    InputStreamBase compressedData = fileData.compressedData;

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

    output.writeInputStream(compressedData);
  }

  void _writeCentralDirectory(List<_ZipFileData> files, String comment,
                              OutputStreamBase output) {
    if (comment == null) {
      comment = "";
    }

    int centralDirPosition = output.length;
    int version = VERSION;
    int os = OS_MSDOS;

    for (var fileData in files) {
      int versionMadeBy = (os << 8) | version;
      int versionNeededToExtract = version;
      int generalPurposeBitFlag = 0;
      int compressionMethod = fileData.compress ? ZipFile.DEFLATE : ZipFile.STORE;
      int lastModifiedFileTime = fileData.time;
      int lastModifiedFileDate = fileData.date;
      int crc32 = fileData.crc32;
      int compressedSize = fileData.compressedSize;
      int uncompressedSize = fileData.uncompressedSize;
      int diskNumberStart = 0;
      int internalFileAttributes = 0;
      int externalFileAttributes = 0;
      int localHeaderOffset = fileData.position;
      List<int> extraField = [];
      String fileComment = fileData.comment;
      if (fileComment == null) {
        fileComment = '';
      }

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
      output.writeUint16(fileData.name.length);
      output.writeUint16(extraField.length);
      output.writeUint16(fileComment.length);
      output.writeUint16(diskNumberStart);
      output.writeUint16(internalFileAttributes);
      output.writeUint32(externalFileAttributes);
      output.writeUint32(localHeaderOffset);
      output.writeBytes(fileData.name.codeUnits);
      output.writeBytes(extraField);
      output.writeBytes(fileComment.codeUnits);
    }

    int numberOfThisDisk = 0;
    int diskWithTheStartOfTheCentralDirectory = 0;
    int totalCentralDirectoryEntriesOnThisDisk = files.length;
    int totalCentralDirectoryEntries = files.length;
    int centralDirectorySize = output.length - centralDirPosition;
    int centralDirectoryOffset = centralDirPosition;

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

import '../../util/input_stream.dart';
import 'zip_file.dart';

class ZipFileHeader {
  static const int signature = 0x02014b50;
  int versionMadeBy = 0;
  int versionNeededToExtract = 0;
  int generalPurposeBitFlag = 0;
  int compressionMethod = 0;
  int lastModifiedFileTime = 0;
  int lastModifiedFileDate = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  int diskNumberStart = 0;
  int internalFileAttributes = 0;
  int externalFileAttributes = 0;
  int localHeaderOffset = 0;
  String filename = '';
  List<int> extraField = [];
  String fileComment = '';
  ZipFile? file;

  Future<void> read(InputStream input,
      {InputStream? fileBytes, String? password}) async {
    versionMadeBy = await input.readUint16();
    versionNeededToExtract = await input.readUint16();
    generalPurposeBitFlag = await input.readUint16();
    compressionMethod = await input.readUint16();
    lastModifiedFileTime = await input.readUint16();
    lastModifiedFileDate = await input.readUint16();
    crc32 = await input.readUint32();
    compressedSize = await input.readUint32();
    uncompressedSize = await input.readUint32();
    final fnameLen = await input.readUint16();
    final extraLen = await input.readUint16();
    final commentLen = await input.readUint16();
    diskNumberStart = await input.readUint16();
    internalFileAttributes = await input.readUint16();
    externalFileAttributes = await input.readUint32();
    localHeaderOffset = await input.readUint32();

    if (fnameLen > 0) {
      filename = await input.readString(size: fnameLen);
    }

    if (extraLen > 0) {
      final extra = await input.readBytes(extraLen);
      extraField = await extra.toUint8List();
      // Rewind to start of the extra fields to read field by field.
      await extra.rewind(extraLen);

      final id = await extra.readUint16();
      var size = await extra.readUint16();
      if (id == 1) {
        // Zip64 extended information
        // The following is the layout of the zip64 extended
        // information "extra" block. If one of the size or
        // offset fields in the Local or Central directory
        // record is too small to hold the required data,
        // a Zip64 extended information record is created.
        // The order of the fields in the zip64 extended
        // information record is fixed, but the fields MUST
        // only appear if the corresponding Local or Central
        // directory record field is set to 0xFFFF or 0xFFFFFFFF.
        // Original
        // Size       8 bytes    Original uncompressed file size
        // Compressed
        // Size       8 bytes    Size of compressed data
        // Relative Header
        // Offset     8 bytes    Offset of local header record
        // Disk Start
        // Number     4 bytes    Number of the disk on which
        // this file starts
        if (size >= 8 && uncompressedSize == 0xffffffff) {
          uncompressedSize = await extra.readUint64();
          size -= 8;
        }
        if (size >= 8 && compressedSize == 0xffffffff) {
          compressedSize = await extra.readUint64();
          size -= 8;
        }
        if (size >= 8 && localHeaderOffset == 0xffffffff) {
          localHeaderOffset = await extra.readUint64();
          size -= 8;
        }
        if (size >= 4 && diskNumberStart == 0xffff) {
          diskNumberStart = await extra.readUint32();
          size -= 4;
        }
      }
    }

    if (commentLen > 0) {
      fileComment = await input.readString(size: commentLen);
    }

    if (fileBytes != null) {
      await fileBytes.setPosition(localHeaderOffset);
      file = ZipFile(this);
      await file!.read(fileBytes, password: password);
    }
  }

  @override
  String toString() => filename;
}

part of dart_archive;

class ZipFileHeader {
  static const int SIGNATURE = 0x02014b50;
  int versionMadeBy = 0; // 2 bytes
  int versionNeededToExtract = 0; // 2 bytes
  int generalPurposeBitFlag = 0; // 2 bytes
  int compressionMethod = 0; // 2 bytes
  int lastModifiedFileTime = 0; // 2 bytes
  int lastModifiedFileDate = 0; // 2 bytes
  int crc32; // 4 bytes
  int compressedSize; // 4 bytes
  int uncompressedSize; // 4 bytes
  int diskNumberStart; // 2 bytes
  int internalFileAttributes; // 2 bytes
  int externalFileAttributes; // 4 bytes
  int localHeaderOffset; // 4 bytes
  String filename = '';
  List<int> extraField = [];
  String fileComment = '';
  ZipFile file;

  ZipFileHeader([InputBuffer input, InputBuffer bytes]) {
    if (input != null) {
      versionMadeBy = input.readUint16();
      versionNeededToExtract = input.readUint16();
      generalPurposeBitFlag = input.readUint16();
      compressionMethod = input.readUint16();
      lastModifiedFileTime = input.readUint16();
      lastModifiedFileDate = input.readUint16();
      crc32 = input.readUint32();
      compressedSize = input.readUint32();
      uncompressedSize = input.readUint32();
      int fname_len = input.readUint16();
      int extra_len = input.readUint16();
      int comment_len = input.readUint16();
      diskNumberStart = input.readUint16();
      internalFileAttributes = input.readUint16();
      externalFileAttributes = input.readUint32();
      localHeaderOffset = input.readUint32();

      if (fname_len > 0) {
        filename = new String.fromCharCodes(input.readBytes(fname_len));
      }

      if (extra_len > 0) {
        extraField = input.readBytes(extra_len);
      }

      if (comment_len > 0) {
        fileComment = new String.fromCharCodes(input.readBytes(comment_len));
      }

      if (bytes != null) {
        bytes.position = localHeaderOffset;
        file = new ZipFile(bytes);
      }
    }
  }
}

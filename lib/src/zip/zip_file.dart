part of dart_archive;

class ZipFile {
  static const int SIGNATURE = 0x04034b50;

  int signature = SIGNATURE; // 4 bytes
  int version = 0; // 2 bytes
  int flags = 0; // 2 bytes
  int compressionMethod = 0; // 2 bytes
  int lastModFileTime = 0; // 2 bytes
  int lastModFileDate = 0; // 2 bytes
  int crc32; // 4 bytes
  int compressedSize; // 4 bytes
  int uncompressedSize; // 4 bytes
  String filename = ''; // 2 bytes length, n-bytes data
  List<int> extraField = []; // 2 bytes length, n-bytes data
  InputBuffer _content;

  ZipFile([InputBuffer input]) {
    if (input != null) {
      signature = input.readUint32();
      if (signature != SIGNATURE) {
        throw 'Invalid Zip Signature';
      }
      version = input.readUint16();
      flags = input.readUint16();
      compressionMethod = input.readUint16();
      lastModFileTime = input.readUint16();
      lastModFileDate = input.readUint16();
      crc32 = input.readUint32();
      compressedSize = input.readUint32();
      uncompressedSize = input.readUint32();
      int fn_len = input.readUint16();
      int ex_len = input.readUint16();
      filename = new String.fromCharCodes(input.readBytes(fn_len));
      if (ex_len > 0) {
        extraField = input.readBytes(ex_len);
      }

      _content = input.subset(null, compressedSize);
    }
  }

  List<int> get content {
    if (_decompressed == null) {
      _decompressed = new Inflate(_content).decompress().getBytes();
      _content = null;
    }
    return _decompressed;
  }

  List<int> _decompressed;
}

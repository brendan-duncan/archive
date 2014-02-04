part of archive;

/**
 * Decompress bzip2 compressed data.
 * Derived from libbzip2 (http://www.bzip.org).
 */
class BZip2Decoder {
  List<int> decodeBytes(List<int> data, {bool verify: true}) {
    return decodeBuffer(new InputStream(data), verify: verify);
  }

  List<int> decodeBuffer(InputStream input, {bool verify: false}) {
    int blockSize100k = 0;
    int signature = input.readUint24();
    if (signature != BZ2_SIGNATURE) {
      throw new ArchiveException('Invalid BZip2 Signature');
    }

    int blockSize = input.readByte() - BZ_HDR_0;
    if (blockSize < 0 || blockSize > 9) {
      throw new ArchiveException('Invalid BlockSize');
    }

    tt = new Data.Uint32List(blockSize * 100000);

    int blockHeader = input.readByte();
    //....

    return null;
  }

  Data.Uint32List tt;
  static const int BZ2_SIGNATURE = 0x685a42;
  static const int BZ_HDR_0 = 0x30;
}

part of dart_archive;

/**
 * Decompress data with the zlib format decoder.
 */
class ZLibDecoder {
  static const int DEFLATE = 8;

  List<int> decode(List<int> data, {bool readHeader: true,
                   bool verify: false}) {
    _ByteBuffer fp = new _ByteBuffer.read(data);

    if (readHeader) {
      int b = fp.readByte();
      int method = b & 0xf;
      if (method != DEFLATE) {
        throw new Exception('unsupported compression method');
      }

      int flags = fp.readByte();
      if (((b << 8) + flags) % 31 != 0) {
        throw new Exception('invalid flag: ${((method << 8) + flags) % 31}');
      }

      // fdict (not supported)
      if (flags & 0x20 != 0) {
        throw new Exception('fdict flag is not supported');
      }
    }

    // Inflate
    List<int> buffer = new _Inflate(fp).decompress();

    // verify adler-32
    if (verify) {
      int adler32 = fp.readUint32();
      if (adler32 != _adler32(buffer)) {
        throw new Exception('invalid adler-32 checksum');
      }
    }

    return buffer;
  }
}

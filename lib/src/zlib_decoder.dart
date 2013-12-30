part of dart_archive;

/**
 * Decompress data with the zlib format decoder.
 */
class ZLibDecoder {
  static const int DEFLATE = 8;

  List<int> decode(List<int> data, {bool verify: false}) {
    InputBuffer input = new InputBuffer(data);

    int b = input.readByte();
    int method = b & 0xf;
    if (method != DEFLATE) {
      throw new Exception('unsupported compression method');
    }

    int flags = input.readByte();
    if (((b << 8) + flags) % 31 != 0) {
      throw new Exception('invalid flag: ${((method << 8) + flags) % 31}');
    }

    // fdict (not supported)
    if (flags & 0x20 != 0) {
      throw new Exception('fdict flag is not supported');
    }

    // Inflate
    OutputBuffer output = new Inflate(input).decompress();
    List<int> buffer = output.getBytes();

    // verify adler-32
    if (verify) {
      int adler32 = input.readUint32();
      if (adler32 != getAdler32(buffer)) {
        throw new Exception('invalid adler-32 checksum');
      }
    }

    return buffer;
  }
}

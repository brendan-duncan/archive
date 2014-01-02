part of archive;

class ZLibEncoder {
  static const int DEFLATE = 8;

  List<int> encode(List<int> data) {
    InputBuffer input = new InputBuffer(data);
    OutputBuffer output = new OutputBuffer();

    // Compression Method and Flags
    int cm = DEFLATE;
    int cinfo = (Math.LOG2E * Math.log(_WINDOW_SIZE)).toInt() - 8;

    int cmf = (cinfo << 4) | cm;
    output.writeByte(cmf);

    // FCHECK is set such that (cmf * 256 + flag) must be a multiple of 31.
    int fdict = 0;
    int flevel = 0;
    int flag = ((flevel & 0x3) << 7) | ((fdict & 0x1) << 5);
    int fcheck = 0;
    int cmf256 = cmf * 256;
    while ((cmf256 + (flag | fcheck)) % 31 != 0) {
      fcheck++;
    }
    flag |= fcheck;
    output.writeByte(flag);

    List<int> compressed = new Deflate(input).getBytes();
    output.writeBytes(compressed);

    int adler32 = getAdler32(data);
    output.writeUint32(adler32);

    return output.getBytes();
  }

  static const int _WINDOW_SIZE = 0x8000;
}

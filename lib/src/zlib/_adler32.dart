part of dart_archive;

int _adler32(List<int> array, [int adler = 1]) {
  const int OptimizationParameter = 1024;

  int s1 = adler & 0xffff;
  int s2 = (adler >> 16) & 0xffff;
  int len = array.length;
  int i = 0;

  while (len > 0) {
    int tlen = len > OptimizationParameter ?
               OptimizationParameter : len;
    len -= tlen;
    do {
      s1 += array[i++];
      s2 += s1;
    } while (--tlen > 0);

    s1 %= 65521;
    s2 %= 65521;
  }

  return ((s2 << 16) | s1) >> 0;
}

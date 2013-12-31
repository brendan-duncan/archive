part of archive;

/**
 * Get the Adler-32 checksum for the given array.
 */
int getAdler32(List<int> array, [int adler = 1]) {
  // largest prime smaller than 65536
  const int BASE = 65521;

  int s1 = adler & 0xffff;
  int s2 = adler >> 16;
  int len = array.length;
  int i = 0;
  while (len > 0) {
    int n = 3800;
    if (n > len) {
      n = len;
    }
    len -= n;
    while (--n >= 0) {
      s1 = s1 + (array[i++] & 0xff);
      s2 = s2 + s1;
    }
    s1 %= BASE;
    s2 %= BASE;
  }

  return (s2 << 16) | s1;
}

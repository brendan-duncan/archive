
import 'input_stream.dart';

int getAdler32Stream(InputStream stream, [int adler = 1]) {
  // largest prime smaller than 65536
  const base = 65521;

  var s1 = adler & 0xffff;
  var s2 = adler >> 16;
  var len = stream.length;
  while (len > 0) {
    var n = 3800;
    if (n > len) {
      n = len;
    }
    len -= n;
    while (--n >= 0) {
      s1 = s1 + stream.readByte();
      s2 = s2 + s1;
    }
    s1 %= base;
    s2 %= base;
  }

  return (s2 << 16) | s1;
}

/// Get the Adler-32 checksum for the given array. You can append bytes to an
/// already computed adler checksum by specifying the previous [adler] value.
int getAdler32(List<int> array, [int adler = 1]) {
  // largest prime smaller than 65536
  const base = 65521;

  var s1 = adler & 0xffff;
  var s2 = adler >> 16;
  var len = array.length;
  var i = 0;
  while (len > 0) {
    var n = 3800;
    if (n > len) {
      n = len;
    }
    len -= n;
    while (--n >= 0) {
      s1 = s1 + (array[i++] & 0xff);
      s2 = s2 + s1;
    }
    s1 %= base;
    s2 %= base;
  }

  return (s2 << 16) | s1;
}

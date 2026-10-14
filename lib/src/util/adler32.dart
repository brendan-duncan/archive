import 'dart:typed_data';

import 'input_memory_stream.dart';
import 'input_stream.dart';

int getAdler32Stream(InputStream stream, [int adler = 1]) {
  if (stream is InputMemoryStream) {
    return getAdler32(stream.readBytes(stream.length).toUint8List(), adler);
  }
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
  if (array is Uint8List) {
    return _adler32Bytes(array, adler);
  }
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

int _adler32Bytes(Uint8List array, int adler) {
  const base = 65521;

  var s1 = adler & 0xffff;
  var s2 = adler >> 16;
  var len = array.length;
  var i = 0;
  while (len > 0) {
    final n = len < 3800 ? len : 3800;
    len -= n;
    final end = i + n;
    final end8 = end - 8;
    while (i <= end8) {
      s1 += array[i];
      s2 += s1;
      s1 += array[i + 1];
      s2 += s1;
      s1 += array[i + 2];
      s2 += s1;
      s1 += array[i + 3];
      s2 += s1;
      s1 += array[i + 4];
      s2 += s1;
      s1 += array[i + 5];
      s2 += s1;
      s1 += array[i + 6];
      s2 += s1;
      s1 += array[i + 7];
      s2 += s1;
      i += 8;
    }
    for (; i < end; i++) {
      s1 += array[i];
      s2 += s1;
    }
    s1 %= base;
    s2 %= base;
  }

  return (s2 << 16) | s1;
}

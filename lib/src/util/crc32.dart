import 'dart:typed_data';

/// Get the CRC-32 checksum of the given int.
int getCrc32Byte(int crc, int b) => _crc32Table[(crc ^ b) & 0xff] ^ (crc >> 8);

/// Get the CRC-32 checksum of the given array. You can append bytes to an
/// already computed crc by specifying the previous [crc] value.
int getCrc32(List<int> array, [int crc = 0]) {
  if (_has64BitInt && array is Uint8List && array.length > 72) {
    return _crc32Chorba(array, crc);
  }
  if (array is Uint8List && array.length >= 32) {
    return _crc32Fast(array, crc);
  }
  var len = array.length;
  crc = crc ^ 0xffffffff;
  var ip = 0;
  while (len >= 8) {
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    len -= 8;
  }
  if (len > 0) {
    do {
      crc = _crc32Table[(crc ^ array[ip++]) & 0xff] ^ (crc >> 8);
    } while (--len > 0);
  }
  return crc ^ 0xffffffff;
}

/// Slice-by-32 tables built from the byte at a time one. Table k holds the
/// contribution of a byte sitting k places from the end of the 32 byte
/// window. The 32 lookups are independent that way, and the loop folds 32
/// bytes at once
Uint32List? _tables;

Uint32List _buildTables(List<int> base) {
  final tables = Uint32List(32 * 256);
  for (var i = 0; i < 256; i++) {
    tables[i] = base[i];
  }
  for (var k = 1; k < 32; k++) {
    for (var i = 0; i < 256; i++) {
      final p = tables[(k - 1) * 256 + i];
      tables[k * 256 + i] = (p >>> 8) ^ tables[p & 0xff];
    }
  }
  return tables;
}

int _crc32Fast(Uint8List array, int crc) {
  final tables = _tables ??= _buildTables(_crc32Table);
  final length = array.length;
  final bytes = ByteData.view(array.buffer, array.offsetInBytes, length);
  var value = crc ^ 0xffffffff;
  var i = 0;
  final limit = length - 32;
  while (i <= limit) {
    final a0 = value ^ bytes.getUint32(i, Endian.little);
    final a1 = bytes.getUint32(i + 4, Endian.little);
    final a2 = bytes.getUint32(i + 8, Endian.little);
    final a3 = bytes.getUint32(i + 12, Endian.little);
    final a4 = bytes.getUint32(i + 16, Endian.little);
    final a5 = bytes.getUint32(i + 20, Endian.little);
    final a6 = bytes.getUint32(i + 24, Endian.little);
    final a7 = bytes.getUint32(i + 28, Endian.little);
    value = tables[0x1f00 + (a0 & 0xff)] ^
        tables[0x1e00 + ((a0 >>> 8) & 0xff)] ^
        tables[0x1d00 + ((a0 >>> 16) & 0xff)] ^
        tables[0x1c00 + (a0 >>> 24)] ^
        tables[0x1b00 + (a1 & 0xff)] ^
        tables[0x1a00 + ((a1 >>> 8) & 0xff)] ^
        tables[0x1900 + ((a1 >>> 16) & 0xff)] ^
        tables[0x1800 + (a1 >>> 24)] ^
        tables[0x1700 + (a2 & 0xff)] ^
        tables[0x1600 + ((a2 >>> 8) & 0xff)] ^
        tables[0x1500 + ((a2 >>> 16) & 0xff)] ^
        tables[0x1400 + (a2 >>> 24)] ^
        tables[0x1300 + (a3 & 0xff)] ^
        tables[0x1200 + ((a3 >>> 8) & 0xff)] ^
        tables[0x1100 + ((a3 >>> 16) & 0xff)] ^
        tables[0x1000 + (a3 >>> 24)] ^
        tables[0xf00 + (a4 & 0xff)] ^
        tables[0xe00 + ((a4 >>> 8) & 0xff)] ^
        tables[0xd00 + ((a4 >>> 16) & 0xff)] ^
        tables[0xc00 + (a4 >>> 24)] ^
        tables[0xb00 + (a5 & 0xff)] ^
        tables[0xa00 + ((a5 >>> 8) & 0xff)] ^
        tables[0x900 + ((a5 >>> 16) & 0xff)] ^
        tables[0x800 + (a5 >>> 24)] ^
        tables[0x700 + (a6 & 0xff)] ^
        tables[0x600 + ((a6 >>> 8) & 0xff)] ^
        tables[0x500 + ((a6 >>> 16) & 0xff)] ^
        tables[0x400 + (a6 >>> 24)] ^
        tables[0x300 + (a7 & 0xff)] ^
        tables[0x200 + ((a7 >>> 8) & 0xff)] ^
        tables[0x100 + ((a7 >>> 16) & 0xff)] ^
        tables[a7 >>> 24];
    i += 32;
  }
  while (i < length) {
    value = tables[(value ^ array[i++]) & 0xff] ^ (value >>> 8);
  }
  return value ^ 0xffffffff;
}

const _has64BitInt = bool.fromEnvironment('dart.library.isolate') ||
    bool.fromEnvironment('dart.tool.dart2wasm');

int _crc32Chorba(Uint8List array, int crc) {
  final length = array.length;
  final bytes = ByteData.view(array.buffer, array.offsetInBytes, length);
  var next1 = crc ^ 0xffffffff;
  var next2 = 0;
  var next3 = 0;
  var next4 = 0;
  var next5 = 0;
  var i = 0;
  for (; i + 72 < length; i += 32) {
    final in1 = bytes.getUint64(i, Endian.little) ^ next1;
    final in2 = bytes.getUint64(i + 8, Endian.little) ^ next2;
    final a1 = (in1 << 17) ^ (in1 << 55);
    final a2 = (in1 >>> 47) ^ (in1 >>> 9) ^ (in1 << 19);
    final a3 = (in1 >>> 45) ^ (in1 << 44);
    final a4 = in1 >>> 20;
    final b1 = (in2 << 17) ^ (in2 << 55);
    final b2 = (in2 >>> 47) ^ (in2 >>> 9) ^ (in2 << 19);
    final b3 = (in2 >>> 45) ^ (in2 << 44);
    final b4 = in2 >>> 20;
    final in3 = bytes.getUint64(i + 16, Endian.little) ^ next3 ^ a1;
    final in4 = bytes.getUint64(i + 24, Endian.little) ^ next4 ^ a2 ^ b1;
    final c1 = (in3 << 17) ^ (in3 << 55);
    final c2 = (in3 >>> 47) ^ (in3 >>> 9) ^ (in3 << 19);
    final c3 = (in3 >>> 45) ^ (in3 << 44);
    final c4 = in3 >>> 20;
    final d1 = (in4 << 17) ^ (in4 << 55);
    final d2 = (in4 >>> 47) ^ (in4 >>> 9) ^ (in4 << 19);
    final d3 = (in4 >>> 45) ^ (in4 << 44);
    final d4 = in4 >>> 20;
    next1 = next5 ^ a3 ^ b2 ^ c1;
    next2 = a4 ^ b3 ^ c2 ^ d1;
    next3 = b4 ^ c3 ^ d2;
    next4 = c4 ^ d3;
    next5 = d4;
  }
  final rest = length - i;
  final tail = Uint8List(72)..setRange(0, rest, array, i);
  final words = ByteData.view(tail.buffer);
  final next = [next1, next2, next3, next4, next5];
  for (var k = 0; k < 5; k++) {
    words.setUint64(
        k * 8, words.getUint64(k * 8, Endian.little) ^ next[k], Endian.little);
  }
  var value = 0;
  for (var k = 0; k < rest; k++) {
    value = _crc32Table[(value ^ tail[k]) & 0xff] ^ (value >>> 8);
  }
  return value ^ 0xffffffff;
}

// Precomputed CRC table for faster calculations.
const _crc32Table = <int>[
  0,
  1996959894,
  3993919788,
  2567524794,
  124634137,
  1886057615,
  3915621685,
  2657392035,
  249268274,
  2044508324,
  3772115230,
  2547177864,
  162941995,
  2125561021,
  3887607047,
  2428444049,
  498536548,
  1789927666,
  4089016648,
  2227061214,
  450548861,
  1843258603,
  4107580753,
  2211677639,
  325883990,
  1684777152,
  4251122042,
  2321926636,
  335633487,
  1661365465,
  4195302755,
  2366115317,
  997073096,
  1281953886,
  3579855332,
  2724688242,
  1006888145,
  1258607687,
  3524101629,
  2768942443,
  901097722,
  1119000684,
  3686517206,
  2898065728,
  853044451,
  1172266101,
  3705015759,
  2882616665,
  651767980,
  1373503546,
  3369554304,
  3218104598,
  565507253,
  1454621731,
  3485111705,
  3099436303,
  671266974,
  1594198024,
  3322730930,
  2970347812,
  795835527,
  1483230225,
  3244367275,
  3060149565,
  1994146192,
  31158534,
  2563907772,
  4023717930,
  1907459465,
  112637215,
  2680153253,
  3904427059,
  2013776290,
  251722036,
  2517215374,
  3775830040,
  2137656763,
  141376813,
  2439277719,
  3865271297,
  1802195444,
  476864866,
  2238001368,
  4066508878,
  1812370925,
  453092731,
  2181625025,
  4111451223,
  1706088902,
  314042704,
  2344532202,
  4240017532,
  1658658271,
  366619977,
  2362670323,
  4224994405,
  1303535960,
  984961486,
  2747007092,
  3569037538,
  1256170817,
  1037604311,
  2765210733,
  3554079995,
  1131014506,
  879679996,
  2909243462,
  3663771856,
  1141124467,
  855842277,
  2852801631,
  3708648649,
  1342533948,
  654459306,
  3188396048,
  3373015174,
  1466479909,
  544179635,
  3110523913,
  3462522015,
  1591671054,
  702138776,
  2966460450,
  3352799412,
  1504918807,
  783551873,
  3082640443,
  3233442989,
  3988292384,
  2596254646,
  62317068,
  1957810842,
  3939845945,
  2647816111,
  81470997,
  1943803523,
  3814918930,
  2489596804,
  225274430,
  2053790376,
  3826175755,
  2466906013,
  167816743,
  2097651377,
  4027552580,
  2265490386,
  503444072,
  1762050814,
  4150417245,
  2154129355,
  426522225,
  1852507879,
  4275313526,
  2312317920,
  282753626,
  1742555852,
  4189708143,
  2394877945,
  397917763,
  1622183637,
  3604390888,
  2714866558,
  953729732,
  1340076626,
  3518719985,
  2797360999,
  1068828381,
  1219638859,
  3624741850,
  2936675148,
  906185462,
  1090812512,
  3747672003,
  2825379669,
  829329135,
  1181335161,
  3412177804,
  3160834842,
  628085408,
  1382605366,
  3423369109,
  3138078467,
  570562233,
  1426400815,
  3317316542,
  2998733608,
  733239954,
  1555261956,
  3268935591,
  3050360625,
  752459403,
  1541320221,
  2607071920,
  3965973030,
  1969922972,
  40735498,
  2617837225,
  3943577151,
  1913087877,
  83908371,
  2512341634,
  3803740692,
  2075208622,
  213261112,
  2463272603,
  3855990285,
  2094854071,
  198958881,
  2262029012,
  4057260610,
  1759359992,
  534414190,
  2176718541,
  4139329115,
  1873836001,
  414664567,
  2282248934,
  4279200368,
  1711684554,
  285281116,
  2405801727,
  4167216745,
  1634467795,
  376229701,
  2685067896,
  3608007406,
  1308918612,
  956543938,
  2808555105,
  3495958263,
  1231636301,
  1047427035,
  2932959818,
  3654703836,
  1088359270,
  936918000,
  2847714899,
  3736837829,
  1202900863,
  817233897,
  3183342108,
  3401237130,
  1404277552,
  615818150,
  3134207493,
  3453421203,
  1423857449,
  601450431,
  3009837614,
  3294710456,
  1567103746,
  711928724,
  3020668471,
  3272380065,
  1510334235,
  755167117
];

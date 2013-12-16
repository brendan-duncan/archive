part of dart_archive;

class _ZlibDeflate {
  static const int MAX_MEM_LEVEL = 9;
  static const int Z_DEFAULT_COMPRESSION = -1;
  static const int MAX_WBITS = 15;            // 32K LZ77 window
  static const int DEF_MEM_LEVEL = 8;
  static const int STORED = 0;
  static const int FAST = 1;
  static const int SLOW = 2;

  static final List<_ZlibConfig> config_table = [
    new _ZlibConfig(0,    0,    0,    0, STORED),
    new _ZlibConfig(4,    4,    8,    4, FAST),
    new _ZlibConfig(4,    5,   16,    8, FAST),
    new _ZlibConfig(4,    6,   32,   32, FAST),
    new _ZlibConfig(4,    4,   16,   16, SLOW),
    new _ZlibConfig(8,   16,   32,   32, SLOW),
    new _ZlibConfig(8,   16,  128,  128, SLOW),
    new _ZlibConfig(8,   32,  128,  256, SLOW),
    new _ZlibConfig(32, 128,  258, 1024, SLOW),
    new _ZlibConfig(32, 258,  258, 4096, SLOW)
  ];

  static const List<String> z_errmsg = const [
    "need dictionary",     // Z_NEED_DICT       2
    "stream end",          // Z_STREAM_END      1
    "",                    // Z_OK              0
    "file error",          // Z_ERRNO         (-1)
    "stream error",        // Z_STREAM_ERROR  (-2)
    "data error",          // Z_DATA_ERROR    (-3)
    "insufficient memory", // Z_MEM_ERROR     (-4)
    "buffer error",        // Z_BUF_ERROR     (-5)
    "incompatible version",// Z_VERSION_ERROR (-6)
    ""
  ];
}


class _ZlibConfig {
  int good_length; // reduce lazy search above this match length
  int max_lazy;    // do not perform lazy search above this match length
  int nice_length; // quit search above this match length
  int max_chain;
  int func;

  _ZlibConfig(this.good_length, this.max_lazy,
              this.nice_length, this.max_chain, this.func);
}
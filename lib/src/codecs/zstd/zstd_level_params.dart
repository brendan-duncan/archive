/// Fast is one table, double adds a second over eight bytes, greedy takes the
/// longest of a row, lazy looks a position or two on, and the binary tree keeps
/// every candidate of a hash ordered so the longest is found rather than
/// sampled
const zstdStrategyFast = 0;
const zstdStrategyDouble = 1;
const zstdStrategyGreedy = 2;
const zstdStrategyLazy = 3;
const zstdStrategyBinaryTree = 4;
const zstdStrategyOptimal = 5;

/// What each level asks of the parse, following libzstd's own table
class ZstdLevelParams {
  final int strategy;

  /// How far back a match may reach, the reference's own `W` column. It decides
  /// both what the parse can find and how much window a decoder has to hold
  final int windowLog;
  final int hashLog;
  final int chainLog;

  final int searchLog;

  /// The reference's `TL` column, the step for the fast parse and the
  /// length that satisfies the optimal one. The greedy and lazy rows hold
  /// instead a length that ends their search at once, which the reference does
  /// not do: measured byte identical on 312 MB and 1% faster
  final int targetLength;

  /// Positions past a match to look at for a longer one. The optimal parse
  /// uses it as its price precision, and three turns on the extra pass over
  /// the first block that seeds its statistics
  final int depth;

  /// How many bytes the table is keyed on. A match still only has to agree on
  /// four, so a wider key raises not the minimum but the odds of a long match
  final int hashBytes;

  /// The reference's own strategy number, one to nine, which the long distance
  /// matcher reads directly rather than through the six the parse has
  final int refStrategy;

  const ZstdLevelParams(
      this.strategy,
      this.windowLog,
      this.hashLog,
      this.chainLog,
      this.searchLog,
      this.targetLength,
      this.depth,
      this.hashBytes,
      this.refStrategy);
}

const _fast = 0;
const _dfast = 1;
const _greedy = 2;
const _lazy = 3;
const _lazy2 = 4;
const _btlazy2 = 5;
const _btopt = 6;
const _btultra = 7;
const _btultra2 = 8;

/// The reference names nine strategies where the parse here has six, each pair
/// differing only in how far past a match it looks
const _strategyOf = <int>[
  zstdStrategyFast,
  zstdStrategyDouble,
  zstdStrategyGreedy,
  zstdStrategyLazy,
  zstdStrategyLazy,
  zstdStrategyBinaryTree,
  zstdStrategyOptimal,
  zstdStrategyOptimal,
  zstdStrategyOptimal,
];
const _depthOf = <int>[0, 0, 0, 1, 2, 2, 0, 2, 3];

const _columns = 7;

/// `clevels.h`, one row a level, columns W, C, H, S, L, TL, strategy
const _large = <int>[
  19, 12, 13, 1, 6, 1, _fast, //
  19, 13, 14, 1, 7, 0, _fast, //
  20, 15, 16, 1, 6, 0, _fast, //
  21, 16, 17, 1, 5, 0, _dfast, //
  21, 18, 18, 1, 5, 0, _dfast, //
  21, 18, 19, 3, 5, 64, _greedy, //
  21, 18, 19, 3, 5, 64, _lazy, //
  21, 19, 20, 4, 5, 96, _lazy, //
  21, 19, 20, 4, 5, 128, _lazy2, //
  22, 20, 21, 4, 5, 128, _lazy2, //
  22, 21, 22, 5, 5, 192, _lazy2, //
  22, 21, 22, 6, 5, 256, _lazy2, //
  22, 22, 23, 6, 5, 512, _lazy2, //
  22, 22, 22, 4, 5, 32, _btlazy2, //
  22, 22, 23, 5, 5, 32, _btlazy2, //
  22, 23, 23, 6, 5, 32, _btlazy2, //
  22, 22, 22, 5, 5, 48, _btopt, //
  23, 23, 22, 5, 4, 64, _btopt, //
  23, 23, 22, 6, 3, 64, _btultra, //
  23, 24, 22, 7, 3, 256, _btultra2, //
  25, 25, 23, 7, 3, 256, _btultra2, //
  26, 26, 24, 7, 3, 512, _btultra2, //
  27, 27, 25, 9, 3, 999, _btultra2, //
];

const _upTo256k = <int>[
  18, 12, 13, 1, 5, 1, _fast, //
  18, 13, 14, 1, 6, 0, _fast, //
  18, 14, 14, 1, 5, 0, _dfast, //
  18, 16, 16, 1, 4, 0, _dfast, //
  18, 16, 17, 3, 5, 64, _greedy, //
  18, 17, 18, 5, 5, 64, _greedy, //
  18, 18, 19, 3, 5, 64, _lazy, //
  18, 18, 19, 4, 4, 96, _lazy, //
  18, 18, 19, 4, 4, 128, _lazy2, //
  18, 18, 19, 5, 4, 128, _lazy2, //
  18, 18, 19, 6, 4, 192, _lazy2, //
  18, 18, 19, 5, 4, 12, _btlazy2, //
  18, 19, 19, 7, 4, 12, _btlazy2, //
  18, 18, 19, 4, 4, 16, _btopt, //
  18, 18, 19, 4, 3, 32, _btopt, //
  18, 18, 19, 6, 3, 128, _btopt, //
  18, 19, 19, 6, 3, 128, _btultra, //
  18, 19, 19, 8, 3, 256, _btultra, //
  18, 19, 19, 6, 3, 128, _btultra2, //
  18, 19, 19, 8, 3, 256, _btultra2, //
  18, 19, 19, 10, 3, 512, _btultra2, //
  18, 19, 19, 12, 3, 512, _btultra2, //
  18, 19, 19, 13, 3, 999, _btultra2, //
];

const _upTo128k = <int>[
  17, 12, 12, 1, 5, 1, _fast, //
  17, 12, 13, 1, 6, 0, _fast, //
  17, 13, 15, 1, 5, 0, _fast, //
  17, 15, 16, 2, 5, 0, _dfast, //
  17, 17, 17, 2, 4, 0, _dfast, //
  17, 16, 17, 3, 4, 64, _greedy, //
  17, 16, 17, 3, 4, 64, _lazy, //
  17, 16, 17, 3, 4, 96, _lazy2, //
  17, 16, 17, 4, 4, 128, _lazy2, //
  17, 16, 17, 5, 4, 128, _lazy2, //
  17, 16, 17, 6, 4, 192, _lazy2, //
  17, 17, 17, 5, 4, 8, _btlazy2, //
  17, 18, 17, 7, 4, 12, _btlazy2, //
  17, 18, 17, 3, 4, 12, _btopt, //
  17, 18, 17, 4, 3, 32, _btopt, //
  17, 18, 17, 6, 3, 256, _btopt, //
  17, 18, 17, 6, 3, 128, _btultra, //
  17, 18, 17, 8, 3, 256, _btultra, //
  17, 18, 17, 10, 3, 512, _btultra, //
  17, 18, 17, 5, 3, 256, _btultra2, //
  17, 18, 17, 7, 3, 512, _btultra2, //
  17, 18, 17, 9, 3, 512, _btultra2, //
  17, 18, 17, 11, 3, 999, _btultra2, //
];

const _upTo16k = <int>[
  14, 12, 13, 1, 5, 1, _fast, //
  14, 14, 15, 1, 5, 0, _fast, //
  14, 14, 15, 1, 4, 0, _fast, //
  14, 14, 15, 2, 4, 0, _dfast, //
  14, 14, 14, 4, 4, 64, _greedy, //
  14, 14, 14, 3, 4, 64, _lazy, //
  14, 14, 14, 4, 4, 64, _lazy2, //
  14, 14, 14, 6, 4, 96, _lazy2, //
  14, 14, 14, 8, 4, 128, _lazy2, //
  14, 15, 14, 5, 4, 8, _btlazy2, //
  14, 15, 14, 9, 4, 8, _btlazy2, //
  14, 15, 14, 3, 4, 12, _btopt, //
  14, 15, 14, 4, 3, 24, _btopt, //
  14, 15, 14, 5, 3, 32, _btultra, //
  14, 15, 15, 6, 3, 64, _btultra, //
  14, 15, 15, 7, 3, 256, _btultra, //
  14, 15, 15, 5, 3, 48, _btultra2, //
  14, 15, 15, 6, 3, 128, _btultra2, //
  14, 15, 15, 7, 3, 256, _btultra2, //
  14, 15, 15, 8, 3, 256, _btultra2, //
  14, 15, 15, 8, 3, 512, _btultra2, //
  14, 15, 15, 9, 3, 512, _btultra2, //
  14, 15, 15, 10, 3, 999, _btultra2, //
];

const _tables = <List<int>>[_large, _upTo256k, _upTo128k, _upTo16k];

const zstdDefaultLevel = 3;
const zstdMaxLevel = 22;

/// `ZSTD_minCLevel()`, the fastest `--fast` level
const zstdMinLevel = -131072;

/// `ZSTD_c_compressionLevel`: zero is the reference's own default and a level
/// above the table is clamped. Below zero selects the `--fast` parse, clamped
/// at [zstdMinLevel]
int zstdEffectiveLevel(int level) {
  if (level < zstdMinLevel) {
    return zstdMinLevel;
  }
  if (level == 0) {
    return zstdDefaultLevel;
  }
  return level > zstdMaxLevel ? zstdMaxLevel : level;
}

/// `ZSTD_minGain`'s shift. What a block or a literals section has to save
/// before it is worth sending coded rather than as it stands, a sixty fourth
/// of it and two bytes, less as the level searches harder
int zstdGainLog(ZstdLevelParams params) =>
    params.strategy == zstdStrategyOptimal && params.depth >= 2
        ? params.depth + 5
        : 6;

/// `ZSTD_minLiteralsToCompress`: below this many literals a tree cannot pay
/// for its own description, so the bytes go as they stand
int zstdMinLiteralsToCompress(ZstdLevelParams params) {
  if (params.strategy != zstdStrategyOptimal) {
    return 64;
  }
  return params.depth == 0 ? 32 : (params.depth == 2 ? 16 : 8);
}

/// [level] read from the row the reference picks for [size] bytes of input,
/// then trimmed the way `ZSTD_adjustCParams_internal` trims it. A smaller input
/// gets its own row, not the large one cut down: it keys the table on fewer
/// bytes, which finds the short matches a wider key would have hashed apart
ZstdLevelParams zstdParamsForLevel(int level, int size) {
  final pick = zstdEffectiveLevel(level);
  final table = _tables[(size <= 262144 ? 1 : 0) +
      (size <= 131072 ? 1 : 0) +
      (size <= 16384 ? 1 : 0)];
  final at = (pick < 0 ? 0 : pick) * _columns;
  final kind = table[at + 6];
  var windowLog = table[at];
  var chainLog = table[at + 1];
  var hashLog = table[at + 2];
  var srcLog = 6;
  while (srcLog < 31 && (1 << srcLog) < size) {
    srcLog++;
  }
  if (windowLog > srcLog) {
    windowLog = srcLog;
  }
  if (hashLog > windowLog + 1) {
    hashLog = windowLog + 1;
  }
  final cycleLog = chainLog - (kind >= _btlazy2 ? 1 : 0);
  if (cycleLog > windowLog) {
    chainLog -= cycleLog - windowLog;
  }
  if (windowLog < 10) {
    windowLog = 10;
  }
  return ZstdLevelParams(
      _strategyOf[kind],
      windowLog,
      hashLog,
      chainLog,
      table[at + 3],
      pick < 0 ? -pick : table[at + 5],
      _depthOf[kind],
      table[at + 4],
      kind + 1);
}

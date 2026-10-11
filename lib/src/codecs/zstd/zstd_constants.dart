import 'dart:typed_data';

const zstdMagic = 0xfd2fb528;

const zstdSkippableMagicMin = 0x184d2a50;
const zstdSkippableMagicMax = 0x184d2a5f;

const zstdDictionaryMagic = 0xec30a437;

const zstdBlockMaximumSize = 128 * 1024;

/// The format allows up to 3.75 TB. This matches the reference decoder's own
/// default ceiling, above which a frame is rejected rather than allocated for
const zstdDefaultMaxWindowSize = 1 << 27;

const zstdBlockRaw = 0;
const zstdBlockRle = 1;
const zstdBlockCompressed = 2;
const zstdBlockReserved = 3;

const zstdLiteralsRaw = 0;
const zstdLiteralsRle = 1;
const zstdLiteralsCompressed = 2;
const zstdLiteralsTreeless = 3;

const zstdModePredefined = 0;
const zstdModeRle = 1;
const zstdModeCompressed = 2;
const zstdModeRepeat = 3;

const zstdLiteralsLengthCodeMax = 35;
const zstdMatchLengthCodeMax = 52;

/// The format lets a decoder pick this. 31 matches the reference decoder and
/// keeps `1 << code` in 32 bits
const zstdOffsetCodeMax = 31;

const zstdLiteralsLengthLogMax = 9;
const zstdMatchLengthLogMax = 9;
const zstdOffsetLogMax = 8;

/// Copies inside the sequence loop write in eight and sixteen byte chunks and
/// are allowed to run past the end of what they copy, so the block's output and
/// the literals it reads need this much room between and after them
const zstdCopySlack = 64;

/// The three sequence tables share one array, so a state value has the base
/// of its own table and the loop needs a single pointer for all three
const zstdLiteralsLengthTableBase = 0;
const zstdOffsetTableBase = 1 << zstdLiteralsLengthLogMax;
const zstdMatchLengthTableBase = zstdOffsetTableBase + (1 << zstdOffsetLogMax);
const zstdBuiltTableRows =
    zstdMatchLengthTableBase + (1 << zstdMatchLengthLogMax);

/// The predefined tables sit in the same array at their own bases, so choosing
/// them is choosing a base rather than copying four kilobytes into place
const zstdPredefinedLiteralsLengthTableBase = zstdBuiltTableRows;
const zstdPredefinedOffsetTableBase = zstdPredefinedLiteralsLengthTableBase +
    (1 << zstdPredefinedLiteralsLengthLog);
const zstdPredefinedMatchLengthTableBase =
    zstdPredefinedOffsetTableBase + (1 << zstdPredefinedOffsetLog);
const zstdSeqTableRows =
    zstdPredefinedMatchLengthTableBase + (1 << zstdPredefinedMatchLengthLog);

const zstdPredefinedLiteralsLengthLog = 6;
const zstdPredefinedMatchLengthLog = 6;
const zstdPredefinedOffsetLog = 5;
const zstdPredefinedOffsetCodeMax = 28;

const zstdHuffmanWeightLogMax = 6;
const zstdHuffmanLogMax = 11;
const zstdHuffmanSymbolCount = 256;

const zstdRepeatOffsetCount = 3;

final Uint32List zstdInitialRepeatOffsets =
    Uint32List.fromList(const [1, 4, 8]);

final Uint32List zstdLiteralsLengthBaseline = Uint32List.fromList(const [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, //
  48, 64, 128, 256, 512, 1024, 2048, 4096, //
  8192, 16384, 32768, 65536,
]);

final Uint8List zstdLiteralsLengthExtraBits = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, //
  4, 6, 7, 8, 9, 10, 11, 12, //
  13, 14, 15, 16,
]);

final Uint32List zstdMatchLengthBaseline = Uint32List.fromList(const [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, //
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, //
  35, 37, 39, 41, 43, 47, 51, 59, //
  67, 83, 99, 131, 259, 515, 1027, 2051, //
  4099, 8195, 16387, 32771, 65539,
]);

final Uint8List zstdMatchLengthExtraBits = Uint8List.fromList(const [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, //
  4, 4, 5, 7, 8, 9, 10, 11, //
  12, 13, 14, 15, 16,
]);

/// Offset codes are their own extra bit count, and their baseline is one
/// shifted by the code
final Uint32List zstdOffsetBaseline =
    Uint32List.fromList([for (var i = 0; i <= zstdOffsetCodeMax; i++) 1 << i]);

final Uint8List zstdOffsetExtraBits =
    Uint8List.fromList([for (var i = 0; i <= zstdOffsetCodeMax; i++) i]);

/// Which of the three sequence tables a build or a lookup is about
const zstdSlotLiteralsLength = 0;
const zstdSlotOffset = 1;
const zstdSlotMatchLength = 2;

final List<Uint32List> zstdSlotBaselines = [
  zstdLiteralsLengthBaseline,
  zstdOffsetBaseline,
  zstdMatchLengthBaseline,
];

final List<Uint8List> zstdSlotExtraBits = [
  zstdLiteralsLengthExtraBits,
  zstdOffsetExtraBits,
  zstdMatchLengthExtraBits,
];

/// Highest set bit for every state a table build can produce, since the
/// branching form of it costs five compares where a native decoder spends one
/// instruction
final Uint8List zstdHighBitTable = _buildHighBitTable();

Uint8List _buildHighBitTable() {
  final table = Uint8List(1 << 11);
  for (var i = 1; i < table.length; i++) {
    table[i] = zstdHighestBit(i);
  }
  return table;
}

/// Undefined for zero and for anything with the sign bit set, where
/// [int.bitLength] counts the magnitude instead
@pragma('vm:prefer-inline')
int zstdHighestBit(int value) => value.bitLength - 1;

// Separate words keep the unused constant parseable on JavaScript
const _deBruijn = (0x022fdd63 << 32) | 0xcc95386d;

/// The bit index for each de Bruijn slot. A `const` list so that reading it is
/// a load, where a lazily built one costs a call to its initialiser guard on
/// every access
const List<int> _deBruijnSlots = [
  0,
  1,
  2,
  53,
  3,
  7,
  54,
  27,
  4,
  38,
  41,
  8,
  34,
  55,
  48,
  28,
  62,
  5,
  39,
  46,
  44,
  42,
  22,
  9,
  24,
  35,
  59,
  56,
  49,
  18,
  29,
  11,
  63,
  52,
  6,
  26,
  37,
  40,
  33,
  47,
  61,
  45,
  43,
  21,
  23,
  58,
  17,
  10,
  51,
  25,
  36,
  32,
  60,
  20,
  57,
  16,
  50,
  31,
  19,
  15,
  30,
  14,
  13,
  12
];

/// The same as [zstdHighestBit] without the call `int.bitLength` compiles to.
/// A call clobbers every live register, so in a loop that keeps state in
/// registers it costs far more than the dozen operations here: 8% at level 9
/// and 9% at level 12
@pragma('vm:prefer-inline')
int zstdHighestBitFast(int value) {
  if (!const bool.fromEnvironment('dart.library.isolate')) {
    return zstdHighestBit(value);
  }
  var v = value;
  v |= v >>> 1;
  v |= v >>> 2;
  v |= v >>> 4;
  v |= v >>> 8;
  v |= v >>> 16;
  v |= v >>> 32;
  return _deBruijnSlots[((v - (v >>> 1)) * _deBruijn) >>> 58];
}

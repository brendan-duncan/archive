import 'dart:typed_data';

import 'zstd_constants.dart';

/// Built on first use and kept, since they never change
final Int16List zstdPredefinedLiteralsLength = Int16List.fromList(const [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1,
]);

final Int16List zstdPredefinedMatchLength = Int16List.fromList(const [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, //
  -1, -1, -1, -1, -1,
]);

/// Tops out at offset code 28
final Int16List zstdPredefinedOffset = Int16List.fromList(const [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
]);

typedef ZstdTableBuilder = void Function(
    int base, int slot, Int16List counts, int maxSymbol, int accuracyLog);

/// Builds the three predefined tables at their own bases, once per decoder, so
/// a block that selects one only has to point at it
void zstdBuildPredefinedTables(ZstdTableBuilder build) {
  build(
      zstdPredefinedLiteralsLengthTableBase,
      zstdSlotLiteralsLength,
      zstdPredefinedLiteralsLength,
      zstdLiteralsLengthCodeMax,
      zstdPredefinedLiteralsLengthLog);
  build(
      zstdPredefinedMatchLengthTableBase,
      zstdSlotMatchLength,
      zstdPredefinedMatchLength,
      zstdMatchLengthCodeMax,
      zstdPredefinedMatchLengthLog);
  build(zstdPredefinedOffsetTableBase, zstdSlotOffset, zstdPredefinedOffset,
      zstdPredefinedOffsetCodeMax, zstdPredefinedOffsetLog);
}

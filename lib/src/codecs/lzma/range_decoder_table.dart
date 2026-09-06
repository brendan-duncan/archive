import 'dart:typed_data';

// Number of bits used for probabilities.
const _probabilityBitCount = 11;

// Value used for a probability of 1.0.
const _probabilityOne = (1 << _probabilityBitCount);

// Value used for a probability of 0.5.
const _probabilityHalf = _probabilityOne ~/ 2;

// Number of probability entries used by [RangeDecoder.decodeLength]. The
// layout is: 0 first form bit, 1 second form bit, 2 the short form bittrees
// (8 entries per position state), 130 the medium form bittrees (8 entries per
// position state), 258 the long form bittree (256 entries).
const lengthProbsLength = 2 + 16 * 8 + 16 * 8 + 256;

// Number of probability entries used by [RangeDecoder.decodeDistance]. The
// layout is: 0 the slot bittrees (64 entries per distance state), 256 the
// reverse bittrees for slots 4-13, 380 the align bittree (16 entries).
const distanceProbsLength = 4 * 64 + 124 + 16;

// Start of each slot 4-13 reverse bittree inside the distance probabilities.
const distanceShortOffsets = <int>[0, 2, 4, 8, 12, 20, 28, 44, 60, 92];

/// Probability table used with [RangeDecoder].
class RangeDecoderTable {
  // Table of probabilities for each symbol.
  final Uint16List table;

  // Creates a new probability table for [length] elements.
  RangeDecoderTable(int length) : table = Uint16List(length) {
    reset();
  }

  // Reset the table to probabilities of 0.5.
  void reset() {
    table.fillRange(0, table.length, _probabilityHalf);
  }
}

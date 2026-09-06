import 'dart:typed_data';

import '../../util/crc32.dart';

// Reads the stream index of an xz archive, which describes every block without
// decoding any of them.
//
// The index is what makes parallel decoding possible: it gives the compressed
// and the uncompressed size of every block, and blocks are independent of each
// other, so where each one sits in the input and in the output can both be
// worked out up front.

/// Random access over the compressed bytes of an xz archive.
///
/// The stream index sits at the end of an archive but describes offsets from
/// its start, so parsing it has to reach both ends. Going through this
/// interface lets a file be indexed without reading all of it into memory.
abstract class XZByteSource {
  /// Total number of bytes in the archive.
  int get length;

  /// The bytes from [start] (inclusive) to [end] (exclusive).
  ///
  /// The result must not be modified by the caller, and may be a view onto
  /// storage the source owns.
  Uint8List range(int start, int end);
}

/// An [XZByteSource] over an archive that is already in memory.
class XZMemorySource extends XZByteSource {
  final Uint8List bytes;

  XZMemorySource(this.bytes);

  @override
  int get length => bytes.length;

  @override
  Uint8List range(int start, int end) =>
      Uint8List.sublistView(bytes, start, end);
}

/// Where a single xz block sits in the input and in the decoded output.
class XZBlockLayout {
  /// Offset of the block header from the start of the archive.
  final int compressedOffset;

  /// Number of bytes the block occupies in the archive, covering the header,
  /// the compressed data, the block padding and the check field.
  final int compressedLength;

  /// Offset of this block's data in the fully decoded output.
  final int outputOffset;

  /// Number of bytes this block decodes to.
  final int uncompressedLength;

  /// Flags of the stream this block belongs to. The low four bits are the
  /// check type, which every block in a stream shares.
  final int streamFlags;

  const XZBlockLayout({
    required this.compressedOffset,
    required this.compressedLength,
    required this.outputOffset,
    required this.uncompressedLength,
    required this.streamFlags,
  });

  /// The type of integrity check stored at the end of the block.
  int get checkType => streamFlags & 0xf;

  /// The size of the check field in bytes.
  int get checkSize => xzCheckSize(checkType);
}

/// The blocks of an archive, in the order they appear.
class XZLayout {
  final List<XZBlockLayout> blocks;

  /// Total size of the decoded output of every stream in the archive.
  final int uncompressedSize;

  const XZLayout(this.blocks, this.uncompressedSize);
}

/// The size in bytes of the check field for [checkType].
///
/// The check types are grouped in threes by size, which is what lets an
/// unrecognised check still be skipped over.
int xzCheckSize(int checkType) {
  if (checkType == 0) {
    return 0;
  } else if (checkType <= 0x3) {
    return 4;
  } else if (checkType <= 0x6) {
    return 8;
  } else if (checkType <= 0x9) {
    return 16;
  } else if (checkType <= 0xc) {
    return 32;
  }
  return 64;
}

/// Reads the layout of every block in [source] from the stream indexes.
///
/// Returns null when the layout cannot be established. This only ever feeds
/// buffer sizing and work scheduling, so anything unexpected makes it give up
/// rather than fail: the data itself is validated when it is decoded.
///
/// [maxUncompressedSize] caps the total decoded size that will be reported. A
/// valid index can describe an output much larger than the available memory,
/// so a caller that is about to allocate that much passes its own ceiling and
/// gets null instead of an unusable answer.
XZLayout? parseXZLayout(XZByteSource source, {int? maxUncompressedSize}) {
  try {
    var end = _skipTrailingZeroPadding(source, source.length);
    var total = 0;

    // Streams are concatenated back to back and only the last one can be found
    // directly, so the archive is walked backwards, one stream footer at a
    // time. Each stream's blocks are collected in order and the streams
    // themselves are reversed at the end.
    final streams = <List<XZBlockLayout>>[];

    while (end > 0) {
      // Stream footer: CRC32 (4), backward size (4), stream flags (2), 'YZ' (2).
      if (end < 32) {
        return null;
      }
      final footerStart = end - 12;
      final footer = source.range(footerStart, end);
      if (footer[10] != 89 /* 'Y' */ || footer[11] != 90 /* 'Z' */) {
        return null;
      }
      if (footer[8] != 0) {
        return null;
      }
      // The footer covers its backward size and flags with a CRC32. Nothing
      // downstream reads these bytes again, so leaving it unchecked would let
      // a damaged footer through a decode that works entirely from the index.
      final footerCrc =
          footer[0] | footer[1] << 8 | footer[2] << 16 | footer[3] << 24;
      if (getCrc32(Uint8List.sublistView(footer, 4, 10)) != footerCrc) {
        return null;
      }
      final streamFlags = footer[9];

      // Backward size holds the size of the index in four byte units, minus one.
      final backwardSize =
          footer[4] | footer[5] << 8 | footer[6] << 16 | footer[7] << 24;
      final indexSize = (backwardSize + 1) * 4;
      final indexStart = footerStart - indexSize;
      // The smallest index is eight bytes, and it is preceded by at least the
      // twelve byte stream header.
      if (indexSize < 8 || indexStart < 12) {
        return null;
      }

      final index = source.range(indexStart, footerStart);
      if (index[0] != 0) {
        return null;
      }
      // The index ends with the CRC32 of everything before it in the index.
      final storedCrc = index[indexSize - 4] |
          index[indexSize - 3] << 8 |
          index[indexSize - 2] << 16 |
          index[indexSize - 1] << 24;
      if (getCrc32(Uint8List.sublistView(index, 0, indexSize - 4)) !=
          storedCrc) {
        return null;
      }

      // Positions below are absolute offsets into the archive, so that the
      // bounds checks read the same way as the offsets being computed.
      final crcStart = footerStart - 4;
      var position = indexStart + 1;
      // Reads a multibyte integer, returning -1 when it is malformed or runs
      // past the last record.
      int readMultibyteInteger() {
        var value = 0;
        var multiplier = 1;

        for (var i = 0; i < 9; i++) {
          if (position >= crcStart) {
            return -1;
          }

          final data = index[position - indexStart];
          position++;
          value += (data & 0x7f) * multiplier;

          if ((data & 0x80) == 0) {
            return value;
          }

          multiplier *= 128;
        }
        return -1;
      }

      final recordCount = readMultibyteInteger();
      // Every record takes at least two bytes.
      if (recordCount < 0 || recordCount > (crcStart - position) ~/ 2) {
        return null;
      }

      // The block sizes are known before the stream header has been located,
      // so blocks are recorded relative to the start of the blocks area and
      // shifted into place once the header has been found.
      final blocks = <XZBlockLayout>[];
      var blocksSize = 0;
      for (var i = 0; i < recordCount; i++) {
        final unpaddedLength = readMultibyteInteger();
        final uncompressedLength = readMultibyteInteger();
        if (unpaddedLength <= 0 ||
            unpaddedLength > indexStart ||
            uncompressedLength < 0) {
          return null;
        }
        // Blocks are padded to a four byte boundary. Every check size is
        // itself a multiple of four, so padding the unpadded size covers the
        // header, the compressed data, the block padding and the check.
        final paddedLength = (unpaddedLength + 3) & ~3;
        if (paddedLength < 0 || paddedLength < unpaddedLength) {
          return null;
        }

        blocks.add(XZBlockLayout(
          compressedOffset: blocksSize,
          compressedLength: paddedLength,
          outputOffset: total,
          uncompressedLength: uncompressedLength,
          streamFlags: streamFlags,
        ));

        blocksSize += paddedLength;
        if (blocksSize < 0) {
          return null;
        }

        total += uncompressedLength;
        if (blocksSize > indexStart ||
            (maxUncompressedSize != null && total > maxUncompressedSize)) {
          return null;
        }
      }

      // The twelve byte stream header sits in front of the blocks.
      final streamStart = indexStart - blocksSize - 12;
      if (streamStart < 0 || streamStart + 12 > source.length) {
        return null;
      }
      final header = source.range(streamStart, streamStart + 12);
      if (header[0] != 253 ||
          header[1] != 55 /* '7' */ ||
          header[2] != 122 /* 'z' */ ||
          header[3] != 88 /* 'X' */ ||
          header[4] != 90 /* 'Z' */ ||
          header[5] != 0) {
        return null;
      }
      // The header repeats the flags that the footer carries.
      if (header[6] != 0 || header[7] != streamFlags) {
        return null;
      }
      // And covers them with its own CRC32, which is the only thing standing
      // between a damaged header and a decode that never looks at it: the
      // blocks are found through the index, so nothing downstream would read
      // these bytes again. Without this an archive that xz rejects decodes
      // here without complaint.
      final headerCrc =
          header[8] | header[9] << 8 | header[10] << 16 | header[11] << 24;
      if (getCrc32(Uint8List.sublistView(header, 6, 8)) != headerCrc) {
        return null;
      }

      final blocksStart = streamStart + 12;
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        blocks[i] = XZBlockLayout(
          compressedOffset: blocksStart + block.compressedOffset,
          compressedLength: block.compressedLength,
          outputOffset: block.outputOffset,
          uncompressedLength: block.uncompressedLength,
          streamFlags: block.streamFlags,
        );
      }
      streams.add(blocks);

      end = _skipTrailingZeroPadding(source, streamStart);
    }

    if (streams.isEmpty) {
      return null;
    }

    // The streams were collected from the last one to the first, and the
    // output offsets were accumulated in that same order, so both are put back
    // into archive order here.
    final blocks = <XZBlockLayout>[];
    for (var i = streams.length - 1; i >= 0; i--) {
      blocks.addAll(streams[i]);
    }
    var outputOffset = 0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      blocks[i] = XZBlockLayout(
        compressedOffset: block.compressedOffset,
        compressedLength: block.compressedLength,
        outputOffset: outputOffset,
        uncompressedLength: block.uncompressedLength,
        streamFlags: block.streamFlags,
      );
      outputOffset += block.uncompressedLength;
    }

    return XZLayout(blocks, total);
  } catch (_) {
    return null;
  }
}

/// Reads the LZMA2 dictionary size out of a block [header].
///
/// A decoder of that block has to allocate a dictionary of this size, so the
/// parallel decoder uses it to work out how many blocks fit in its memory
/// budget rather than guessing. Returns 0 when the header does not name one.
int xzBlockDictionarySize(Uint8List header) {
  try {
    if (header.isEmpty) {
      return 0;
    }
    final headerLength = (header[0] + 1) * 4;
    if (headerLength > header.length) {
      return 0;
    }

    var position = 1;
    int readMultibyteInteger() {
      var value = 0;
      var multiplier = 1;
      for (var i = 0; i < 9; i++) {
        if (position >= headerLength) {
          return -1;
        }
        final data = header[position++];
        value += (data & 0x7f) * multiplier;
        if ((data & 0x80) == 0) {
          return value;
        }
        multiplier *= 128;
      }
      return -1;
    }

    final blockFlags = header[position++];
    final nFilters = (blockFlags & 0x3) + 1;
    if (blockFlags & 0x40 != 0 && readMultibyteInteger() < 0) {
      return 0;
    }
    if (blockFlags & 0x80 != 0 && readMultibyteInteger() < 0) {
      return 0;
    }

    for (var i = 0; i < nFilters; i++) {
      final id = readMultibyteInteger();
      final propertiesLength = readMultibyteInteger();
      if (id < 0 ||
          propertiesLength < 0 ||
          position + propertiesLength > headerLength) {
        return 0;
      }
      if (id == 0x21 && propertiesLength >= 1) {
        // lzma2 filter
        final v = header[position];
        if (v > 40) {
          return 0;
        } else if (v == 40) {
          return 0xffffffff;
        }
        final mantissa = 2 | (v & 0x1);
        final exponent = (v >> 1) + 11;
        return mantissa << exponent;
      }
      position += propertiesLength;
    }
    return 0;
  } catch (_) {
    return 0;
  }
}

// Returns the offset of the start of the stream padding that ends at [end].
// Padding is zero bytes in multiples of four.
int _skipTrailingZeroPadding(XZByteSource source, int end) {
  // Padding is almost always absent, so this reads a small window at a time
  // rather than the whole archive.
  const windowSize = 1024;
  while (end >= 4) {
    final start = end - windowSize < 0 ? 0 : end - windowSize;
    final window = source.range(start, end);
    var i = window.length;
    while (i >= 4 &&
        window[i - 1] == 0 &&
        window[i - 2] == 0 &&
        window[i - 3] == 0 &&
        window[i - 4] == 0) {
      i -= 4;
    }
    final consumed = window.length - i;
    end -= consumed;
    if (consumed < window.length || start == 0) {
      break;
    }
  }
  return end;
}

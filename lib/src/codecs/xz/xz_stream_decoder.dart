import 'dart:typed_data';

import '../../util/byte_order.dart';
import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../../util/sha256.dart';
import '../bcj_x86.dart';
import '../lzma/lzma_decoder.dart';
import 'xz_index.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decodes the xz block at [input]'s current position, without verifying its
/// check. Blocks are independent, so they can run in separate isolates.
({bool ok, String? reason, int unpaddedLength}) decodeXZBlock(
    InputStream input, int streamFlags, OutputStream output,
    {required int maxPreallocateSize,
    bool verify = false,
    int maxDictionarySize = xzDefaultMaxDictionarySize}) {
  final headerByte = input.peekBytes(1).readByte();
  if (headerByte == 0) {
    return (
      ok: false,
      reason: 'Expected a block but found the stream index',
      unpaddedLength: -1
    );
  }
  final decoder = XZStreamDecoder(
      maxPreallocateSize: maxPreallocateSize,
      maxDictionarySize: maxDictionarySize)
    ..streamFlags = streamFlags
    ..checkRangeCoderStart = verify;
  final ok = decoder.readBlock(input, output, (headerByte + 1) * 4);
  return (
    ok: ok,
    reason: ok ? null : decoder.failureReason,
    unpaddedLength: ok ? decoder._blockSizes.last.unpaddedLength : -1
  );
}

/// Default for [XZStreamDecoder.maxDictionarySize]: four times the largest
/// dictionary any of xz's presets uses.
const int xzDefaultMaxDictionarySize = 256 * 1024 * 1024;

const xzCrc32Failed = 'CRC32 check failed';
const xzCrc64Failed = 'CRC64 check failed';
const xzSha256Failed = 'SHA-256 check failed';
const xzBlockCheckFailed = 'Block check failed';

/// Failure reasons that mean a block decoded but its check does not match
const xzCheckFailures = {
  xzCrc32Failed,
  xzCrc64Failed,
  xzSha256Failed,
  xzBlockCheckFailed,
};

const xzStreamHeaderCrcFailed = 'Invalid stream header CRC checksum';
const xzBlockHeaderCrcFailed = 'Invalid block header CRC checksum';
const xzIndexCrcFailed = 'Invalid stream index CRC checksum';
const xzFooterCrcFailed = 'Invalid stream footer CRC checksum';

const xzHeaderCheckFailures = {
  xzStreamHeaderCrcFailed,
  xzBlockHeaderCrcFailed,
  xzIndexCrcFailed,
  xzFooterCrcFailed,
};

bool xzIsCheckFailure(String? reason, bool verify) =>
    xzCheckFailures.contains(reason) ||
    (verify && xzHeaderCheckFailures.contains(reason));

/// True when [reason] reports block whose dictionary exceeds
/// `maxDictionarySize`
bool xzIsLimitFailure(String? reason) =>
    reason != null && reason.startsWith('LZMA dictionary size ');

int xzDictionaryCap(int dictionarySize) =>
    dictionarySize + (dictionarySize >> 2) + (2 << 20) + 16;

/// Decodes an XZ stream.
class XZStreamDecoder {
  // True if checksums are confirmed.
  final bool verify;

  // LZMA decoder.
  final decoder = LzmaDecoder();

  // Stream flags, which are sent in both the header and the footer.
  var streamFlags = 0;

  var checkRangeCoderStart = false;

  // Block sizes.
  final _blockSizes = <_XZBlockSize>[];

  // Position of the start of the stream being decoded. Padding inside a stream
  // is aligned to this, not to the start of [input], which may have been
  // positioned elsewhere by the caller.
  var _streamStart = 0;

  // We still report failure by returning, so a successful decode throws
  // and allocates nothing
  String? failureReason;

  // Upper bound on a buffer sized from a length the archive declares.
  final int maxPreallocateSize;
  // A block decodes on its own, so its first chunk has to start the
  // dictionary: control 1 for an uncompressed chunk, reset 3 for an LZMA one
  var needDictionaryReset = true;
  // liblzma lzma2_decoder.c: the LZMA chunk after a dictionary reset must set
  // new properties
  var needProperties = true;

  // What [readBlockHeader] read last, for [readBlock] and the streamed decoder
  int? blockCompressedLength;
  int? blockUncompressedLength;
  var blockDictionarySize = 0;
  var blockHasX86 = false;
  var blockX86StartOffset = 0;

  // The largest LZMA2 dictionary a block may declare. The dictionary is held
  // in memory as the data decodes, up to a quarter more than its size, so a
  // small archive declaring 4 GB could otherwise take that much memory.
  final int maxDictionarySize;

  XZStreamDecoder(
      {this.verify = false,
      required this.maxPreallocateSize,
      this.maxDictionarySize = xzDefaultMaxDictionarySize});

  // Records why the decode gave up and reports the failure. The first reason
  // is kept, because it is the innermost one: the returns above it only pass
  // the failure outwards and have nothing of their own to add.
  bool _fail(String reason) {
    failureReason ??= reason;
    return false;
  }

  // As [_fail], for the readers that report their failure with a negative
  // length instead of a bool.
  int _failLength(String reason) {
    failureReason ??= reason;
    return -1;
  }

  /// Decode this stream and return the uncompressed data.
  bool decode(InputStream input, OutputStream output) {
    failureReason = null;
    final held = input.byteOrder;
    input.byteOrder = ByteOrder.littleEndian;
    try {
      while (true) {
        if (!_decodeStream(input, output)) {
          return false;
        }

        // Streams can be concatenated, and each one may be followed by padding.
        if (!_skipStreamPadding(input)) {
          return false;
        }
        if (input.isEOS) {
          return true;
        }
      }
    } finally {
      input.byteOrder = held;
    }
  }

  // Decodes a single stream from [input].
  bool _decodeStream(InputStream input, OutputStream output) {
    // Each stream has its own flags, block list and dictionary.
    _streamStart = input.position;
    streamFlags = 0;
    _blockSizes.clear();
    decoder.dictionaryCap = 0;
    decoder.dictionaryLimit = 0;
    decoder.reset(resetDictionary: true);

    if (!_readStreamHeader(input, output)) {
      return false;
    }

    while (!input.isEOS) {
      final blockHeader = input.peekBytes(1).readByte();

      if (blockHeader == 0) {
        final indexSize = _readStreamIndex(input);
        if (indexSize < 0) {
          return false;
        }
        return _readStreamFooter(input, indexSize);
      }

      final blockLength = (blockHeader + 1) * 4;
      if (!readBlock(input, output, blockLength)) {
        return false;
      }
    }

    // Valid XZ always goes trough _readStreamFooter
    return _fail('Stream ended without a footer');
  }

  // Skips the padding that may follow a stream. Padding is zero bytes in
  // multiples of four, and is followed by another stream or the end of the
  // input.
  bool _skipStreamPadding(InputStream input) {
    var count = 0;
    while (!input.isEOS) {
      if (input.peekBytes(1).readByte() != 0) {
        break;
      }
      input.skip(1);
      count++;
    }
    return count % 4 == 0
        ? true
        : _fail('Stream padding is not a multiple of four bytes');
  }

  // Reads an XZ steam header from [input].
  bool _readStreamHeader(InputStream input, OutputStream output) {
    if (input.length < 12) {
      return _fail('Truncated stream header');
    }
    final magic = input.readBytes(6).toUint8List();
    final magicIsValid = magic[0] == 253 &&
        magic[1] == 55 /* '7' */ &&
        magic[2] == 122 /* 'z' */ &&
        magic[3] == 88 /* 'X' */ &&
        magic[4] == 90 /* 'Z' */ &&
        magic[5] == 0;
    if (!magicIsValid) {
      return _fail('Invalid XZ stream header signature');
    }

    final header = input.readBytes(2);
    if (header.readByte() != 0) {
      return _fail('Invalid stream flags');
    }
    streamFlags = header.readByte();
    // Only the low 4 bits of the second byte are the check ID and everything
    // else is reserved, so if any reserved bit is set we don't know how
    // to read this stream
    if (streamFlags & 0xf0 != 0) {
      return _fail('Invalid stream flags');
    }
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return _fail(xzStreamHeaderCrcFailed);
    }

    return true;
  }

  // Reads a data block from [input].
  bool readBlock(InputStream input, OutputStream output, int headerLength) {
    final blockStart = input.position;
    if (!readBlockHeader(input, headerLength)) {
      return false;
    }
    final compressedLength = blockCompressedLength;
    int? uncompressedLength = blockUncompressedLength;
    final dictionarySize = blockDictionarySize;
    final hasX86 = blockHasX86;
    final x86StartOffset = blockX86StartOffset;

    final startPosition = input.position;
    final startDataLength = output.length;

    // A filter or a checksum needs the decoded block again
    final checkType = streamFlags & 0xf;
    final needsBlockData = hasX86 ||
        (verify && (checkType == 0x1 || checkType == 0x4 || checkType == 0xa));
    Uint8List? blockData;

    final verifyCheck =
        verify && (checkType == 0x1 || checkType == 0x4 || checkType == 0xa);
    final checked = verifyCheck && output is! OutputMemoryStream
        // Default 4 MiB buffer, allocated per block, cost 24% more cycles on
        // 1526 blocks of 64 KiB
        ? XzBlockSink((_, piece) => output.writeBytes(piece), 0, checkType,
            stagingSize: 1 << 16)
        : null;
    if (output is! OutputMemoryStream &&
        (checked != null || (hasX86 && !verifyCheck))) {
      final sink = checked ?? output;
      final filtered = hasX86 ? BcjX86OutputStream(sink, x86StartOffset) : null;
      try {
        if (!_readLZMA2(input, filtered ?? sink, dictionarySize)) {
          return false;
        }
        filtered?.finish();
      } finally {
        checked?.flush();
      }
    } else if (needsBlockData && output is! OutputMemoryStream) {
      // Streams that are not backed by a contiguous buffer cannot be read back
      // after the data has been written, so the block is decoded into a
      // temporary buffer and appended afterwards.
      // The declared length is only a hint, so it is not trusted past
      // [maxPreallocateSize]; the stream grows into what the block needs.
      final block = OutputMemoryStream(
          size: uncompressedLength != null &&
                  uncompressedLength <= maxPreallocateSize
              ? uncompressedLength
              : null);
      final bool read;
      try {
        read = _readLZMA2(input, block, dictionarySize);
      } catch (_) {
        // A failure part way through leaves the temporary buffer holding
        // whatever was decoded before it. Handing that over leaves the caller
        // with the same output they would have got had the block been written
        // straight through, so what survives a corrupt archive does not depend
        // on which kind of stream was passed in. The filter is applied to it,
        // matching the branches above and below, which filter it too.
        final partial = block.getBytes();
        final done =
            hasX86 ? bcjX86Decode(partial, x86StartOffset) : partial.length;
        output.writeBytes(Uint8List.sublistView(partial, 0, done));
        rethrow;
      }
      blockData = block.getBytes();
      var done = blockData.length;
      if (hasX86) {
        done = bcjX86Decode(blockData, x86StartOffset);
      }
      if (!read) {
        output.writeBytes(Uint8List.sublistView(blockData, 0, done));
        return false;
      }
      output.writeBytes(blockData);
    } else {
      var read = false;
      try {
        read = _readLZMA2(input, output, dictionarySize);
        if (!read) {
          return false;
        }
      } finally {
        if (hasX86) {
          // subset() returns a view into the output buffer, so the filter is
          // applied in place without allocating a copy of the block.
          final done =
              bcjX86Decode(output.subset(startDataLength), x86StartOffset);
          if (!read && output is OutputMemoryStream) {
            output.length = startDataLength + done;
          }
        }
      }
    }

    final actualCompressedLength = input.position - startPosition;
    final actualUncompressedLength = output.length - startDataLength;

    if (compressedLength != null &&
        compressedLength != actualCompressedLength) {
      return _fail("Compressed data doesn't match the length in the block "
          'header');
    }

    uncompressedLength ??= actualUncompressedLength;
    if (uncompressedLength != actualUncompressedLength) {
      return _fail("Uncompressed data doesn't match the length in the block "
          'header');
    }

    final paddingSize = _readPadding(input, _streamStart);
    if (paddingSize < 0) {
      return _fail('Invalid block padding');
    }
    if (input.length < xzCheckSize(checkType)) {
      return _fail('Block check is truncated');
    }

    // Checksum
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        final stored =
            checked == null ? null : input.peekBytes(4).toUint8List();
        final int expectedCrc = input.readUint32();
        if (verify &&
            (stored != null
                ? !checked!.checkMatches(stored)
                : getCrc32(blockData ?? output.subset(startDataLength)) !=
                    expectedCrc)) {
          return _fail(xzCrc32Failed);
        }
        break;
      case 0x2:
      case 0x3:
        input.skip(4);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0x4: // CRC64
        final stored = input.readBytes(8).toUint8List();
        if (checked != null) {
          if (!checked.checkMatches(stored)) {
            return _fail(xzCrc64Failed);
          }
        } else if (verify) {
          final actual = Crc64()
            ..update(blockData ?? output.subset(startDataLength));
          if (!actual.matches(stored, 0)) {
            return _fail(xzCrc64Failed);
          }
        }
        break;
      case 0x5:
      case 0x6:
        input.skip(8);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0x7:
      case 0x8:
      case 0x9:
        input.skip(16);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0xa: // SHA-256
        final stored = input.readBytes(32).toUint8List();
        if (checked != null) {
          if (!checked.checkMatches(stored)) {
            return _fail(xzSha256Failed);
          }
        } else if (verify) {
          final actual = Sha256.of(blockData ?? output.subset(startDataLength));
          for (var i = 0; i < 32; i++) {
            if (actual[i] != stored[i]) {
              return _fail(xzSha256Failed);
            }
          }
        }
        break;
      case 0xb:
      case 0xc:
        input.skip(32);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0xd:
      case 0xe:
      case 0xf:
        input.skip(64);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      default:
        return _fail('Unknown block check type $checkType');
    }

    final unpaddedLength = input.position - blockStart - paddingSize;
    _blockSizes.add(_XZBlockSize(unpaddedLength, uncompressedLength));

    return true;
  }

  // Reads a block header from [input] into the block fields
  bool readBlockHeader(InputStream input, int headerLength) {
    if (input.length < headerLength) {
      return _fail('Truncated block header');
    }
    final header = input.readBytes(headerLength - 4);

    header.skip(1); // Skip length field
    final blockFlags = header.readByte();
    if (blockFlags & 0x3c != 0) {
      return _fail('Reserved bit is set in the block flags');
    }
    final nFilters = (blockFlags & 0x3) + 1;
    final hasCompressedLength = blockFlags & 0x40 != 0;
    final hasUncompressedLength = blockFlags & 0x80 != 0;

    int? compressedLength;
    if (hasCompressedLength) {
      compressedLength = _readMultibyteInteger(header);
      if (compressedLength < 0) {
        return _fail('Invalid compressed length in block header');
      }
    }
    int? uncompressedLength;
    if (hasUncompressedLength) {
      uncompressedLength = _readMultibyteInteger(header);
      if (uncompressedLength < 0) {
        return _fail('Invalid uncompressed length in block header');
      }
    }

    final filters = <int>[];
    var dictionarySize = 0;

    for (var i = 0; i < nFilters; i++) {
      final id = _readMultibyteInteger(header);
      final propertiesLength = _readMultibyteInteger(header);
      if (id < 0 || propertiesLength < 0) {
        return _fail('Invalid filter in block header');
      }
      final properties = header.readBytes(propertiesLength).toUint8List();
      if (properties.length != propertiesLength) {
        return _fail('Invalid filter in block header');
      }
      if (id == 0x03) {
        // delta filter
        if (propertiesLength != 1) {
          return _fail('Invalid delta filter distance');
        }
        final distance = properties[0];
        filters.add(id);
        filters.add(distance);
      } else if (id == 0x04) {
        // x86 BCJ filter
        if (propertiesLength != 0 && propertiesLength != 4) {
          return _fail('Invalid x86 filter start offset');
        }
        var startOffset = 0;
        if (propertiesLength == 4) {
          startOffset = properties[0] |
              properties[1] << 8 |
              properties[2] << 16 |
              properties[3] << 24;
        }
        filters.add(id);
        filters.add(startOffset);
      } else if (id == 0x21) {
        // lzma2 filter
        if (propertiesLength != 1) {
          return _fail('Invalid LZMA dictionary size');
        }
        final v = properties[0];
        if (v > 40) {
          return _fail('Invalid LZMA dictionary size');
        } else if (v == 40) {
          dictionarySize = 0xffffffff;
        } else {
          final mantissa = 2 | (v & 0x1);
          final exponent = (v >> 1) + 11;
          dictionarySize = mantissa << exponent;
        }
        if (dictionarySize > maxDictionarySize) {
          return _fail('LZMA dictionary size $dictionarySize exceeds '
              'maxDictionarySize $maxDictionarySize');
        }
        filters.add(id);
        filters.add(dictionarySize);
      } else {
        filters.add(id);
        filters.add(0);
      }
    }

    // A match may not reach further back than the declared dictionary. That is
    // a tighter bound than the buffer the dictionary sits in
    decoder.dictionaryLimit = dictionarySize;
    if (dictionarySize > 0 && dictionarySize < 0x40000000) {
      decoder.dictionaryCap = xzDictionaryCap(dictionarySize);
    }

    if (_readPadding(header) < 0) {
      return _fail('Invalid block header padding');
    }
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return _fail(xzBlockHeaderCrcFailed);
    }

    // Entries are stored as (id, value) pairs. The supported chains are LZMA2
    // on its own, or the x86 BCJ filter followed by LZMA2.
    final hasX86 =
        filters.length == 4 && filters[0] == 0x04 && filters[2] == 0x21;
    if (!hasX86 && (filters.length != 2 || filters.first != 0x21)) {
      return _fail('Unsupported filter chain; only LZMA2, optionally behind '
          'the x86 BCJ filter, is supported');
    }
    final x86StartOffset = hasX86 ? filters[1] : 0;
    blockCompressedLength = compressedLength;
    blockUncompressedLength = uncompressedLength;
    blockDictionarySize = dictionarySize;
    blockHasX86 = hasX86;
    blockX86StartOffset = x86StartOffset;
    return true;
  }

  // Reads LZMA2 data from [input].
  bool _readLZMA2(InputStream input, OutputStream output, int dictionarySize) {
    needDictionaryReset = true;
    needProperties = true;
    while (!input.isEOS) {
      final done = readLZMA2Chunk(input, output, dictionarySize);
      if (done != null) {
        return done;
      }
    }

    // 00000000 - end marker, if not reached - there's an issue with file
    return _fail('LZMA2 data ended without an end marker');
  }

  // Reads one LZMA2 chunk from [input]. Returns true at the end marker, false
  // on a failure, and null when another chunk follows
  bool? readLZMA2Chunk(
      InputStream input, OutputStream output, int dictionarySize) {
    if (input.isEOS) {
      return _fail('Truncated LZMA2 chunk');
    }
    final control = input.readByte();
    if (control != 0) {
      final resets =
          control < 0x80 ? control == 1 : ((control >> 5) & 0x3) == 3;
      if (needDictionaryReset && !resets) {
        return _fail('The first LZMA2 chunk does not reset the dictionary');
      }
      needDictionaryReset = false;
      if (resets) {
        needProperties = true;
      }
    }
    // Control values:
    // 00000000 - end marker
    // 00000001 - reset dictionary and uncompresed data
    // 00000010 - uncompressed data
    // 1rrxxxxx - LZMA data with reset (r) and high bits of size field (x)
    final headerLength = control >= 0xc0
        ? 6
        : control >= 0x80
            ? 5
            : control > 0
                ? 2
                : 0;
    if (input.length < headerLength) {
      return _fail('Truncated LZMA2 chunk');
    }
    if (control & 0x80 == 0) {
      if (control == 0) {
        decoder.reset(resetDictionary: true);
        return true;
      } else if (control == 1) {
        decoder.reset(resetDictionary: true);
        final length = (input.readByte() << 8 | input.readByte()) + 1;
        output.writeBytes(
            decoder.decodeUncompressed(input.readBytes(length), length));
        decoder.trimDictionary(dictionarySize);
      } else if (control == 2) {
        // uncompressed data
        final length = (input.readByte() << 8 | input.readByte()) + 1;
        output.writeBytes(
            decoder.decodeUncompressed(input.readBytes(length), length));
        decoder.trimDictionary(dictionarySize);
      } else {
        return _fail('Unknown LZMA2 control code $control');
      }
    } else {
      // Reset flags:
      // 0 - reset nothing
      // 1 - reset state
      // 2 - reset state, properties
      // 3 - reset state, properties and dictionary
      final reset = (control >> 5) & 0x3;
      if (reset < 2 && needProperties) {
        return _fail('LZMA2 chunk does not set new properties after a '
            'dictionary reset');
      }
      final uncompressedLength =
          ((control & 0x1f) << 16 | input.readByte() << 8 | input.readByte()) +
              1;
      final compressedLength = (input.readByte() << 8 | input.readByte()) + 1;
      int? literalContextBits;
      int? literalPositionBits;
      int? positionBits;
      if (reset >= 2) {
        // The three LZMA decoder properties are combined into a single number
        var properties = input.readByte();
        if (properties > 224) {
          return _fail('Invalid LZMA properties byte');
        }
        positionBits = properties ~/ 45;
        properties -= positionBits * 45;
        literalPositionBits = properties ~/ 9;
        literalContextBits = properties - literalPositionBits * 9;
        if (literalContextBits + literalPositionBits > 4) {
          return _fail('Invalid LZMA literal context and position bits');
        }
        needProperties = false;
      }
      if (reset > 0) {
        decoder.reset(
            literalContextBits: literalContextBits,
            literalPositionBits: literalPositionBits,
            positionBits: positionBits,
            resetDictionary: reset == 3);
      }

      if (input.peekBytes(1).readByte() != 0) {
        return _fail('LZMA2 range coder does not start with 0');
      }
      decoder.decodeToOutput(
          input.readBytes(compressedLength), uncompressedLength, output);
      // Checking this can catch some corrupt files, especially if they don't
      // have any other integrity check. An end of payload marker is not
      // allowed in LZMA2, so a chunk that reached its uncompressed size
      // without emptying the range coder is a data error, and so is a chunk
      // that stops at a marker short of it
      if (decoder.endMarkerSeen || !decoder.isRangeCoderFinished) {
        return _fail('LZMA data is corrupt');
      }
      decoder.trimDictionary(dictionarySize);
    }
    return null;
  }

  // Reads an XZ stream index from [input].
  // Returns the length of the index in bytes.
  int _readStreamIndex(InputStream input) {
    final startPosition = input.position;
    input.skip(1); // Skip index indicator
    final nRecords = _readMultibyteInteger(input);
    if (nRecords != _blockSizes.length) {
      return _failLength('Stream index block count mismatch');
    }

    for (var i = 0; i < nRecords; i++) {
      final unpaddedLength = _readMultibyteInteger(input);
      final uncompressedLength = _readMultibyteInteger(input);
      if (_blockSizes[i].unpaddedLength != unpaddedLength) {
        return _failLength('Stream index compressed length mismatch');
      }
      if (_blockSizes[i].uncompressedLength != uncompressedLength) {
        return _failLength('Stream index uncompressed length mismatch');
      }
    }
    if (_readPadding(input, _streamStart) < 0) {
      return _failLength('Invalid stream index padding');
    }

    // Re-read for CRC calculation
    final indexLength = input.position - startPosition;
    input.rewind(indexLength);
    final indexData = input.readBytes(indexLength);

    if (input.length < 4) {
      return _failLength('Truncated stream index');
    }
    final crc = input.readUint32();
    if (getCrc32(indexData.toUint8List()) != crc) {
      return _failLength(xzIndexCrcFailed);
    }

    return indexLength + 4;
  }

  // Reads an XZ stream footer from [input] and check the index size matches
  // [indexSize].
  bool _readStreamFooter(InputStream input, int indexSize) {
    if (input.length < 12) {
      return _fail('Truncated stream footer');
    }
    final crc = input.readUint32();
    final footer = input.readBytes(6);
    final backwardSize = (footer.readUint32() + 1) * 4;
    if (backwardSize != indexSize) {
      return _fail('Stream footer has invalid index size');
    }
    if (footer.readByte() != 0) {
      return _fail('Invalid stream footer flags');
    }
    final footerFlags = footer.readByte();
    if (footerFlags != streamFlags) {
      return _fail("Stream footer flags don't match the header flags");
    }
    footer.reset();

    if (getCrc32(footer.toUint8List()) != crc) {
      return _fail(xzFooterCrcFailed);
    }

    // The stream is invalid if at least one byte is corrupted.
    final magic = input.readBytes(2).toUint8List();
    if (magic[0] != 89 /* 'Y' */ || magic[1] != 90 /* 'Z' */) {
      return _fail('Invalid XZ stream footer signature');
    }

    return true;
  }

  // Reads a multibyte integer from [input], or -1 if there is not a valid one
  // there. Nine bytes is the format's cap; past it the multiplier overflows.
  int _readMultibyteInteger(InputStream input) {
    var value = 0;
    var multiplier = 1;
    for (var i = 0; i < 9; i++) {
      if (input.isEOS) {
        return -1;
      }
      final data = input.readByte();
      value += (data & 0x7f) * multiplier;
      if (data & 0x80 == 0) {
        // liblzma vli_decoder.c takes only the shortest encoding
        if (data == 0 && i > 0) {
          return -1;
        }
        return value;
      }
      multiplier *= 128;
    }
    return -1;
  }

  // Reads padding from [input] until the read position is aligned to a 4 byte
  // boundary. The padding bytes are confirmed to be zeros.
  // Returns he number of padding bytes.
  int _readPadding(InputStream input, [int origin = 0]) {
    var count = 0;
    while ((input.position - origin) % 4 != 0) {
      if (input.isEOS || input.readByte() != 0) {
        return -1;
        //throw ArchiveException('Non-zero padding byte');
      }
      count++;
    }
    return count;
  }
}

// Information about a block size.
class _XZBlockSize {
  // The block size excluding padding.
  final int unpaddedLength;

  // The size of the data in the block when uncompressed.
  final int uncompressedLength;

  const _XZBlockSize(this.unpaddedLength, this.uncompressedLength);
}

// Chunks worker output to prevent massive memory spikes, keeping overhead at
// 4MB instead of holding entire decoded blocks in memory at the cost of a
// memcpy
const xzStagingSize = 4 * 1024 * 1024;

/// An [OutputStream] that passes its writes to [_onPiece] in pieces.
class XzBlockSink extends OutputStream {
  final void Function(int offset, Uint8List piece) _onPiece;
  final int _outputOffset;

  /// Check type to accumulate, or 0 to accumulate nothing.
  final int _checkType;

  final Uint8List _staging;
  int _staged = 0;
  int _emitted = 0;
  int _crc = 0;
  final _sha256 = Sha256();
  final _crc64 = Crc64();

  XzBlockSink(this._onPiece, this._outputOffset, this._checkType,
      {int stagingSize = xzStagingSize})
      : _staging = Uint8List(stagingSize),
        super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _emitted + _staged;

  @override
  void writeByte(int value) {
    if (_staged == _staging.length) {
      flush();
    }
    _staging[_staged++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    if (length <= 0) {
      return;
    }

    // tood profile: check Uint8List(length)..setRange(0, length, bytes)); ??
    if (length >= _staging.length) {
      flush();
      _emit(bytes is Uint8List
          ? Uint8List.sublistView(bytes, 0, length)
          : Uint8List.fromList(bytes.sublist(0, length)));
      return;
    }

    if (_staged + length > _staging.length) {
      flush();
    }
    _staging.setRange(_staged, _staged + length, bytes);
    _staged += length;
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void flush() {
    if (_staged == 0) {
      return;
    }
    _emit(Uint8List.sublistView(_staging, 0, _staged));
    _staged = 0;
  }

  void _emit(Uint8List view) {
    if (view.isEmpty) {
      return;
    }
    if (_checkType == 0x1) {
      _crc = getCrc32(view, _crc);
    } else if (_checkType == 0x4) {
      _crc64.update(view);
    } else if (_checkType == 0xa) {
      _sha256.update(view, 0, view.length);
    }
    _onPiece(_outputOffset + _emitted, view);
    _emitted += view.length;
  }

  /// Compares the accumulated checksum with the [checkField] stored in the
  /// block. Check types that cannot be verified pass.
  bool checkMatches(Uint8List checkField) {
    if (_checkType == 0xa) {
      if (checkField.length != 32) {
        return false;
      }
      final actual = _sha256.digest();
      for (var i = 0; i < 32; i++) {
        if (actual[i] != checkField[i]) {
          return false;
        }
      }
      return true;
    }
    if (_checkType != 0x1 && _checkType != 0x4) {
      return true;
    }
    if (_checkType == 0x4) {
      return checkField.length == 8 && _crc64.matches(checkField, 0);
    }
    if (checkField.isEmpty) {
      return false;
    }

    var expected = 0;
    for (var i = checkField.length - 1; i >= 0; i--) {
      expected = (expected << 8) | checkField[i];
    }
    return expected == _crc;
  }

  @override
  void clear() =>
      throw UnsupportedError('An xz worker sink cannot be rewritten');

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('An xz worker sink cannot be read back');

  @override
  void writeBackReference(int distance, int count) =>
      throw UnsupportedError('An xz worker sink cannot be read back');
}

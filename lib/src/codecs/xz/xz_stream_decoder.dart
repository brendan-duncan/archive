import 'dart:typed_data';

import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../bcj_x86.dart';
import '../lzma/lzma_decoder.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decodes a single xz block that starts at the current position of [input].
///
/// Every block resets the LZMA2 dictionary, so a block can be decoded on its
/// own with no state carried over from the blocks before it. That is what lets
/// blocks be handed out to separate isolates.
///
/// [input] must cover the block from its header up to and including the check
/// field, which is what [XZBlockLayout.compressedLength] measures. It does not
/// have to be backed by memory: reading a block from a file as it is decoded
/// keeps the compressed block out of memory altogether.
///
/// [streamFlags] comes from the stream header or footer; its low four bits
/// select the check type. The check is read but not verified, because a caller
/// decoding into a non-seekable output computes it as the bytes go past
/// instead.
({bool ok, String? reason}) decodeXZBlock(
    InputStream input, int streamFlags, OutputStream output,
    {required int maxPreallocateSize}) {
  final headerByte = input.peekBytes(1).readByte();
  if (headerByte == 0) {
    return (ok: false, reason: 'Expected a block but found the stream index');
  }
  final decoder = XZStreamDecoder(maxPreallocateSize: maxPreallocateSize)
    ..streamFlags = streamFlags;
  final ok = decoder.readBlock(input, output, (headerByte + 1) * 4);
  return (ok: ok, reason: ok ? null : decoder.failureReason);
}

/// Decodes an XZ stream.
class XZStreamDecoder {
  // True if checksums are confirmed.
  final bool verify;

  // LZMA decoder.
  final decoder = LzmaDecoder();

  // Stream flags, which are sent in both the header and the footer.
  var streamFlags = 0;

  // Block sizes.
  final _blockSizes = <_XZBlockSize>[];

  // Position of the start of the stream being decoded. Padding inside a stream
  // is aligned to this, not to the start of [input], which may have been
  // positioned elsewhere by the caller.
  var _streamStart = 0;

  /// Why the last decode gave up, or null if it has not given up.
  ///
  /// Every rejection sets this, so that a caller who asked to be told about
  /// failures gets the reason rather than only the fact. Recording a string is
  /// all it costs: the decoder still reports failure by returning, so nothing
  /// is thrown or allocated on the path that succeeds.
  String? failureReason;

  // Upper bound on a buffer sized from a length the archive declares.
  final int maxPreallocateSize;

  XZStreamDecoder({this.verify = false, required this.maxPreallocateSize});

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
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return _fail('Invalid stream header CRC checksum');
    }

    return true;
  }

  // Reads a data block from [input].
  bool readBlock(InputStream input, OutputStream output, int headerLength) {
    final blockStart = input.position;
    final header = input.readBytes(headerLength - 4);

    header.skip(1); // Skip length field
    final blockFlags = header.readByte();
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
      if (id == 0x03) {
        // delta filter
        if (properties.isEmpty) {
          return _fail('Invalid delta filter distance');
        }
        final distance = properties[0];
        filters.add(id);
        filters.add(distance);
      } else if (id == 0x04) {
        // x86 BCJ filter
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
        if (properties.isEmpty) {
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
        filters.add(id);
        filters.add(dictionarySize);
      } else {
        filters.add(id);
        filters.add(0);
      }
    }

    // A match may not reach further back than the declared dictionary, which
    // is a tighter bound than the buffer the dictionary is held in.
    decoder.dictionaryLimit = dictionarySize;
    if (dictionarySize > 0 && dictionarySize < 0x40000000) {
      decoder.dictionaryCap =
          dictionarySize + (dictionarySize >> 2) + (2 << 20) + 16;
    }

    if (_readPadding(header) < 0) {
      return _fail('Invalid block header padding');
    }
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return _fail('Invalid block header CRC checksum');
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

    final startPosition = input.position;
    final startDataLength = output.length;

    // The decoded block is needed again when a filter has to be applied or a
    // checksum verified.
    final checkType = streamFlags & 0xf;
    final needsBlockData = hasX86 ||
        (verify &&
            (checkType == 0x1 || (checkType == 0x4 && isCrc64Supported())));
    Uint8List? blockData;

    if (needsBlockData && output is! OutputMemoryStream) {
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
        // on which kind of stream was passed in. The filter is not applied to
        // it, matching the branch below, which gives up before filtering too.
        output.writeBytes(block.getBytes());
        rethrow;
      }
      if (!read) {
        output.writeBytes(block.getBytes());
        return false;
      }
      blockData = block.getBytes();
      if (hasX86) {
        bcjX86Decode(blockData, x86StartOffset);
      }
      output.writeBytes(blockData);
    } else {
      if (!_readLZMA2(input, output, dictionarySize)) {
        return false;
      }
      if (hasX86) {
        // subset() returns a view into the output buffer, so the filter is
        // applied in place without allocating a copy of the block.
        bcjX86Decode(output.subset(startDataLength), x86StartOffset);
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

    // Checksum
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        final int expectedCrc = input.readUint32();
        if (verify &&
            getCrc32(blockData ?? output.subset(startDataLength)) !=
                expectedCrc) {
          return _fail('CRC32 check failed');
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
        final int expectedCrc = input.readUint64();
        if (verify &&
            isCrc64Supported() &&
            getCrc64(blockData ?? output.subset(startDataLength)) !=
                expectedCrc) {
          return _fail('CRC64 check failed');
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
        /*final expectedCrc =*/
        input.readBytes(32).toUint8List();
        /*if (verify) {
          final actualCrc =
              sha256.convert(data.toBytes().sublist(startDataLength)).bytes;
          for (var i = 0; i < 32; i++) {
            if (actualCrc[i] != expectedCrc[i]) {
              throw ArchiveException('SHA-256 check failed');
            }
          }
        }*/
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

  // Reads LZMA2 data from [input].
  bool _readLZMA2(InputStream input, OutputStream output, int dictionarySize) {
    while (!input.isEOS) {
      final control = input.readByte();
      // Control values:
      // 00000000 - end marker
      // 00000001 - reset dictionary and uncompresed data
      // 00000010 - uncompressed data
      // 1rrxxxxx - LZMA data with reset (r) and high bits of size field (x)
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
        final uncompressedLength = ((control & 0x1f) << 16 |
                input.readByte() << 8 |
                input.readByte()) +
            1;
        final compressedLength = (input.readByte() << 8 | input.readByte()) + 1;
        int? literalContextBits;
        int? literalPositionBits;
        int? positionBits;
        if (reset >= 2) {
          // The three LZMA decoder properties are combined into a single number.
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
        }
        if (reset > 0) {
          decoder.reset(
              literalContextBits: literalContextBits,
              literalPositionBits: literalPositionBits,
              positionBits: positionBits,
              resetDictionary: reset == 3);
        }

        decoder.decodeToOutput(
            input.readBytes(compressedLength), uncompressedLength, output);
        // Checking this can catch some corrupt files, especially if they don't
        // have any other integrity check. An end of payload marker is not
        // allowed in LZMA2, so a chunk that reached its uncompressed size
        // without emptying the range coder is a data error.
        if (!decoder.isRangeCoderFinished) {
          return _fail('LZMA data is corrupt');
        }
        decoder.trimDictionary(dictionarySize);
      }
    }

    // 00000000 - end marker, if not reached - there's an issue with file
    return _fail('LZMA2 data ended without an end marker');
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

    final crc = input.readUint32();
    if (getCrc32(indexData.toUint8List()) != crc) {
      return _failLength('Invalid stream index CRC checksum');
    }

    return indexLength + 4;
  }

  // Reads an XZ stream footer from [input] and check the index size matches
  // [indexSize].
  bool _readStreamFooter(InputStream input, int indexSize) {
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
      return _fail('Invalid stream footer CRC checksum');
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
      if (input.readByte() != 0) {
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

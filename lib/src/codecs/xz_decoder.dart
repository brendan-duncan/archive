import 'dart:typed_data';

import '../util/crc32.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'lzma/lzma_decoder.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decompress data with the xz format decoder.
class XZDecoder {
  Uint8List decodeBytes(List<int> data, {bool verify = false}) {
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(data), output, verify: verify);
    return output.getBytes();
  }

  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false}) {
    final decoder = _XZStreamDecoder(verify: verify);
    return decoder.decode(input, output);
  }
}

/// Decodes an XZ stream.
class _XZStreamDecoder {
  // True if checksums are confirmed.
  final bool verify;

  // LZMA decoder.
  final decoder = LzmaDecoder();

  // Stream flags, which are sent in both the header and the footer.
  var streamFlags = 0;

  // Block sizes.
  final _blockSizes = <_XZBlockSize>[];

  _XZStreamDecoder({this.verify = false});

  /// Decode this stream and return the uncompressed data.
  bool decode(InputStream input, OutputStream output) {
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
      if (!_readBlock(input, output, blockLength)) {
        return false;
      }
    }

    return true;
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
      return false;
      //throw ArchiveException('Invalid XZ stream header signature');
    }

    final header = input.readBytes(2);
    if (header.readByte() != 0) {
      return false;
      //throw ArchiveException('Invalid stream flags');
    }
    streamFlags = header.readByte();
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid stream header CRC checksum');
    }

    return true;
  }

  // Reads a data block from [input].
  bool _readBlock(InputStream input, OutputStream output, int headerLength) {
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
    }
    int? uncompressedLength;
    if (hasUncompressedLength) {
      uncompressedLength = _readMultibyteInteger(header);
    }

    final filters = <int>[];
    var dictionarySize = 0;
    for (var i = 0; i < nFilters; i++) {
      final id = _readMultibyteInteger(header);
      final propertiesLength = _readMultibyteInteger(header);
      final properties = header.readBytes(propertiesLength).toUint8List();
      if (id == 0x03) {
        // delta filter
        final distance = properties[0];
        filters.add(id);
        filters.add(distance);
      } else if (id == 0x21) {
        // lzma2 filter
        final v = properties[0];
        if (v > 40) {
          return false;
          //throw ArchiveException('Invalid LZMA dictionary size');
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
    if (_readPadding(header) < 0) {
      return false;
    }
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid block CRC checksum');
    }

    if (filters.length != 2 && filters.first != 0x21) {
      return false;
      //throw ArchiveException('Unsupported filters');
    }

    final startPosition = input.position;
    final startDataLength = output.length;

    _readLZMA2(input, output, dictionarySize);

    final actualCompressedLength = input.position - startPosition;
    final actualUncompressedLength = output.length - startDataLength;

    if (compressedLength != null &&
        compressedLength != actualCompressedLength) {
      return false;
      //throw ArchiveException("Compressed data doesn't match expected length");
    }

    uncompressedLength ??= actualUncompressedLength;
    if (uncompressedLength != actualUncompressedLength) {
      return false;
      //throw ArchiveException("Uncompressed data doesn't match expected length");
    }

    final paddingSize = _readPadding(input);
    if (paddingSize < 0) {
      return false;
    }

    // Checksum
    final checkType = streamFlags & 0xf;
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        /*final expectedCrc =*/ input.readUint32();
        /*if (verify) {
          final actualCrc = getCrc32(data.toBytes().sublist(startDataLength));
          if (actualCrc != expectedCrc) {
            throw ArchiveException('CRC32 check failed');
          }
        }*/
        break;
      case 0x2:
      case 0x3:
        input.skip(4);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0x4: // CRC64
        /*final expectedCrc =*/ input.readUint64();
        /*if (verify && isCrc64Supported()) {
          final actualCrc = getCrc64(data.toBytes().sublist(startDataLength));
          if (actualCrc != expectedCrc) {
            throw ArchiveException('CRC64 check failed');
          }
        }*/
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
        /*final expectedCrc =*/ input.readBytes(32).toUint8List();
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
        //throw ArchiveException('Unknown block check type $checkType');
        return false;
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
          final length = (input.readByte() << 8 | input.readByte()) + 1;
          output.writeBytes(input.readBytes(length).toUint8List());
        } else if (control == 2) {
          // uncompressed data
          final length = (input.readByte() << 8 | input.readByte()) + 1;
          output.writeBytes(
              decoder.decodeUncompressed(input.readBytes(length), length));
        } else {
          return false;
          //throw ArchiveException('Unknown LZMA2 control code $control');
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
          positionBits = properties ~/ 45;
          properties -= positionBits * 45;
          literalPositionBits = properties ~/ 9;
          literalContextBits = properties - literalPositionBits * 9;
        }
        if (reset > 0) {
          decoder.reset(
              literalContextBits: literalContextBits,
              literalPositionBits: literalPositionBits,
              positionBits: positionBits,
              resetDictionary: reset == 3);
        }

        output.writeBytes(decoder.decode(
            input.readBytes(compressedLength), uncompressedLength));
      }
    }

    return true;
  }

  // Reads an XZ stream index from [input].
  // Returns the length of the index in bytes.
  int _readStreamIndex(InputStream input) {
    final startPosition = input.position;
    input.skip(1); // Skip index indicator
    final nRecords = _readMultibyteInteger(input);
    if (nRecords != _blockSizes.length) {
      return -1;
      //throw ArchiveException('Stream index block count mismatch');
    }

    for (var i = 0; i < nRecords; i++) {
      final unpaddedLength = _readMultibyteInteger(input);
      final uncompressedLength = _readMultibyteInteger(input);
      if (_blockSizes[i].unpaddedLength != unpaddedLength) {
        return -1;
        //throw ArchiveException('Stream index compressed length mismatch');
      }
      if (_blockSizes[i].uncompressedLength != uncompressedLength) {
        return -1;
        //throw ArchiveException('Stream index uncompressed length mismatch');
      }
    }
    if (_readPadding(input) < 0) {
      return -1;
    }

    // Re-read for CRC calculation
    final indexLength = input.position - startPosition;
    input.rewind(indexLength);
    final indexData = input.readBytes(indexLength);

    final crc = input.readUint32();
    if (getCrc32(indexData.toUint8List()) != crc) {
      return -1;
      //throw ArchiveException('Invalid stream index CRC checksum');
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
      return false;
      //throw ArchiveException('Stream footer has invalid index size');
    }
    if (footer.readByte() != 0) {
      return false;
      //throw ArchiveException('Invalid stream flags');
    }
    final footerFlags = footer.readByte();
    if (footerFlags != streamFlags) {
      return false;
      //throw ArchiveException("Stream footer flags don't match header flags");
    }
    footer.reset();

    if (getCrc32(footer.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid stream footer CRC checksum');
    }

    final magic = input.readBytes(2).toUint8List();
    if (magic[0] != 89 /* 'Y' */ && magic[1] != 90 /* 'Z' */) {
      return false;
      //throw ArchiveException('Invalid XZ stream footer signature');
    }

    return true;
  }

  // Reads a multibyte integer from [input].
  int _readMultibyteInteger(InputStream input) {
    var value = 0;
    var shift = 0;
    while (true) {
      final data = input.readByte();
      value |= (data & 0x7f) << shift;
      if (data & 0x80 == 0) {
        return value;
      }
      shift += 7;
    }
  }

  // Reads padding from [input] until the read position is aligned to a 4 byte
  // boundary. The padding bytes are confirmed to be zeros.
  // Returns he number of padding bytes.
  int _readPadding(InputStream input) {
    var count = 0;
    while (input.position % 4 != 0) {
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

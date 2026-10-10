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
    _state = _XZState.streamHeader;
    while (step(input, output)) {}
    return failureReason == null;
  }

  // Where the decoder is between steps.
  _XZState _state = _XZState.streamHeader;

  /// Decodes the next piece of the input: a stream header, a block header, an
  /// LZMA2 chunk, the end of a block, or the index and footer of a stream.
  ///
  /// Returns false once the input has been decoded, or decoding has failed,
  /// in which case [failureReason] says why. Decoding a piece at a time is
  /// what lets the output be pulled out of the decoder as it is read, by
  /// `XZDecoder.decodeLazy`, rather than pushed into it all at once.
  bool step(InputStream input, OutputStream output) {
    switch (_state) {
      case _XZState.streamHeader:
        if (!_startStream(input)) {
          return _stop();
        }
        _state = _XZState.block;
        return true;

      case _XZState.block:
        if (input.isEOS) {
          // Valid XZ always goes through the stream footer.
          _fail('Stream ended without a footer');
          return _stop();
        }
        final blockHeader = input.peekBytes(1).readByte();
        if (blockHeader == 0) {
          final indexSize = _readStreamIndex(input);
          if (indexSize < 0 || !_readStreamFooter(input, indexSize)) {
            return _stop();
          }
          // Streams can be concatenated, and each one may be followed by
          // padding.
          if (!_skipStreamPadding(input)) {
            return _stop();
          }
          if (input.isEOS) {
            _state = _XZState.done;
            return false;
          }
          _state = _XZState.streamHeader;
          return true;
        }
        if (!_startBlock(input, output, (blockHeader + 1) * 4)) {
          return _stop();
        }
        _state = _XZState.chunk;
        return true;

      case _XZState.chunk:
        final int result;
        try {
          result = _readLZMA2Chunk(input, _blockOutput!);
        } catch (_) {
          _abandonBlock(output);
          rethrow;
        }
        if (result < 0) {
          _abandonBlock(output);
          return _stop();
        }
        if (result == 0) {
          if (!_finishBlock(input, output)) {
            return _stop();
          }
          _state = _XZState.block;
        }
        return true;

      case _XZState.done:
        return false;
    }
  }

  bool _stop() {
    _state = _XZState.done;
    return false;
  }

  // Begins a stream. Each stream has its own flags, block list and
  // dictionary.
  bool _startStream(InputStream input) {
    _streamStart = input.position;
    streamFlags = 0;
    _blockSizes.clear();
    decoder.dictionaryCap = 0;
    decoder.dictionaryLimit = 0;
    decoder.reset(resetDictionary: true);
    return _readStreamHeader(input);
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
  bool _readStreamHeader(InputStream input) {
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
    if (!_startBlock(input, output, headerLength)) {
      return false;
    }
    try {
      while (true) {
        final result = _readLZMA2Chunk(input, _blockOutput!);
        if (result < 0) {
          _abandonBlock(output);
          return false;
        }
        if (result == 0) {
          break;
        }
      }
    } catch (_) {
      // A failure part way through leaves the temporary buffer holding
      // whatever was decoded before it. Handing that over leaves the caller
      // with the same output they would have got had the block been written
      // straight through, so what survives a corrupt archive does not depend
      // on which kind of stream was passed in. The filter is not applied to
      // it, matching the branch below, which gives up before filtering too.
      _abandonBlock(output);
      rethrow;
    }
    return _finishBlock(input, output);
  }

  // The block being decoded, between _startBlock and _finishBlock.
  int _blockStart = 0;
  int _blockDataStart = 0;
  int _blockOutputStart = 0;
  int? _blockCompressedLength;
  int? _blockUncompressedLength;
  int _dictionarySize = 0;
  bool _hasX86 = false;
  int _x86StartOffset = 0;
  // Where the LZMA2 chunks are written: the output, or a buffer of the block
  // when a filter has to be applied to the whole of it first, either behind
  // a stream that sums the check as the data goes past.
  OutputStream? _blockOutput;
  OutputMemoryStream? _blockBuffer;
  _CheckOutputStream? _blockCheck;

  // Reads a block header from [input] and gets ready to decode its chunks.
  bool _startBlock(InputStream input, OutputStream output, int headerLength) {
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
      if (properties.length != propertiesLength) {
        return _fail('Invalid filter in block header');
      }
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

    _blockStart = blockStart;
    _blockDataStart = input.position;
    _blockOutputStart = output.length;
    _blockCompressedLength = compressedLength;
    _blockUncompressedLength = uncompressedLength;
    _dictionarySize = dictionarySize;
    _hasX86 = hasX86;
    _x86StartOffset = hasX86 ? filters[1] : 0;

    // The x86 filter works on the whole block, so unless the output can be
    // reached back into the block is decoded into a buffer and appended
    // afterwards. The declared length is only a hint, so it is not trusted
    // past [maxPreallocateSize]; the buffer grows into what the block needs.
    _blockBuffer = hasX86 && output is! OutputMemoryStream
        ? OutputMemoryStream(
            size: uncompressedLength != null &&
                    uncompressedLength <= maxPreallocateSize
                ? uncompressedLength
                : null)
        : null;
    final OutputStream target = _blockBuffer ?? output;

    // The check is summed as the data goes past, so that nothing has to be
    // read back. Not when a filter still has to run over the data, since the
    // check covers its result.
    final checkType = streamFlags & 0xf;
    _blockCheck = verify &&
            !hasX86 &&
            (checkType == 0x1 || (checkType == 0x4 && isCrc64Supported()))
        ? _CheckOutputStream(target, crc64: checkType == 0x4)
        : null;
    _blockOutput = _blockCheck ?? target;
    return true;
  }

  // What a failed block leaves behind: the buffered part of it, if it was
  // being buffered, goes to the output so that what survives a corrupt
  // archive does not depend on the kind of output.
  void _abandonBlock(OutputStream output) {
    final buffer = _blockBuffer;
    if (buffer != null) {
      output.writeBytes(buffer.getBytes());
      _blockBuffer = null;
    }
  }

  // Applies the filter, checks the lengths and the check, and records the
  // block in the sizes the index is compared against.
  bool _finishBlock(InputStream input, OutputStream output) {
    Uint8List? blockData;
    if (_hasX86) {
      final buffer = _blockBuffer;
      if (buffer != null) {
        blockData = buffer.getBytes();
        bcjX86Decode(blockData, _x86StartOffset);
        output.writeBytes(blockData);
        _blockBuffer = null;
      } else {
        // subset() returns a view into the output buffer, so the filter is
        // applied in place without allocating a copy of the block.
        blockData = output.subset(_blockOutputStart);
        bcjX86Decode(blockData, _x86StartOffset);
      }
    }

    final actualCompressedLength = input.position - _blockDataStart;
    final actualUncompressedLength = output.length - _blockOutputStart;

    final compressedLength = _blockCompressedLength;
    if (compressedLength != null &&
        compressedLength != actualCompressedLength) {
      return _fail("Compressed data doesn't match the length in the block "
          'header');
    }

    final uncompressedLength =
        _blockUncompressedLength ?? actualUncompressedLength;
    if (uncompressedLength != actualUncompressedLength) {
      return _fail("Uncompressed data doesn't match the length in the block "
          'header');
    }

    final paddingSize = _readPadding(input, _streamStart);
    if (paddingSize < 0) {
      return _fail('Invalid block padding');
    }

    // Checksum
    final checkType = streamFlags & 0xf;
    final check = _blockCheck;
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        final int expectedCrc = input.readUint32();
        if (verify) {
          final actual = check != null ? check.crc : getCrc32(blockData!);
          if (actual != expectedCrc) {
            return _fail('CRC32 check failed');
          }
        }
        break;
      case 0x2:
      case 0x3:
        input.skip(4);
        break;
      case 0x4: // CRC64
        final int expectedCrc = input.readUint64();
        if (verify && isCrc64Supported()) {
          final actual = check != null ? check.crc : getCrc64(blockData!);
          if (actual != expectedCrc) {
            return _fail('CRC64 check failed');
          }
        }
        break;
      case 0x5:
      case 0x6:
        input.skip(8);
        break;
      case 0x7:
      case 0x8:
      case 0x9:
        input.skip(16);
        break;
      case 0xa: // SHA-256
        input.readBytes(32).toUint8List();
        break;
      case 0xb:
      case 0xc:
        input.skip(32);
        break;
      case 0xd:
      case 0xe:
      case 0xf:
        input.skip(64);
        break;
      default:
        return _fail('Unknown block check type $checkType');
    }

    final unpaddedLength = input.position - _blockStart - paddingSize;
    _blockSizes.add(_XZBlockSize(unpaddedLength, uncompressedLength));

    return true;
  }

  // Reads one LZMA2 chunk from [input], writing its data to [output].
  // Returns 1 when there are more chunks to come, 0 at the end marker, and
  // -1 for bad data.
  int _readLZMA2Chunk(InputStream input, OutputStream output) {
    if (input.isEOS) {
      // 00000000 - end marker, if not reached - there's an issue with file
      return _failLength('LZMA2 data ended without an end marker');
    }
    final dictionarySize = _dictionarySize;
    final control = input.readByte();
    // Control values:
    // 00000000 - end marker
    // 00000001 - reset dictionary and uncompresed data
    // 00000010 - uncompressed data
    // 1rrxxxxx - LZMA data with reset (r) and high bits of size field (x)
    if (control & 0x80 == 0) {
      if (control == 0) {
        decoder.reset(resetDictionary: true);
        return 0;
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
        return _failLength('Unknown LZMA2 control code $control');
      }
      return 1;
    }

    // Reset flags:
    // 0 - reset nothing
    // 1 - reset state
    // 2 - reset state, properties
    // 3 - reset state, properties and dictionary
    final reset = (control >> 5) & 0x3;
    final uncompressedLength =
        ((control & 0x1f) << 16 | input.readByte() << 8 | input.readByte()) + 1;
    final compressedLength = (input.readByte() << 8 | input.readByte()) + 1;
    int? literalContextBits;
    int? literalPositionBits;
    int? positionBits;
    if (reset >= 2) {
      // The three LZMA decoder properties are combined into a single number.
      var properties = input.readByte();
      if (properties > 224) {
        return _failLength('Invalid LZMA properties byte');
      }
      positionBits = properties ~/ 45;
      properties -= positionBits * 45;
      literalPositionBits = properties ~/ 9;
      literalContextBits = properties - literalPositionBits * 9;
      if (literalContextBits + literalPositionBits > 4) {
        return _failLength('Invalid LZMA literal context and position bits');
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
      return _failLength('LZMA data is corrupt');
    }
    decoder.trimDictionary(dictionarySize);
    return 1;
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

enum _XZState { streamHeader, block, chunk, done }

/// Passes what is written through to another stream, summing its CRC-32 or
/// CRC-64 on the way.
class _CheckOutputStream extends OutputStream {
  final OutputStream _output;
  final bool _crc64;
  int crc = 0;
  final _one = Uint8List(1);

  _CheckOutputStream(this._output, {required bool crc64})
      : _crc64 = crc64,
        super(byteOrder: _output.byteOrder);

  @override
  int get length => _output.length;

  void _sum(List<int> bytes) {
    crc = _crc64 ? getCrc64(bytes, crc) : getCrc32(bytes, crc);
  }

  @override
  void writeByte(int value) {
    _one[0] = value;
    _sum(_one);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    if (length != null && length != bytes.length) {
      bytes = bytes is Uint8List
          ? Uint8List.sublistView(bytes, 0, length)
          : bytes.sublist(0, length);
    }
    _sum(bytes);
    _output.writeBytes(bytes);
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void flush() => _output.flush();

  @override
  void clear() => _output.clear();

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}

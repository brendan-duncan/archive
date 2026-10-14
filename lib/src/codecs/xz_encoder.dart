import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/byte_order.dart';
import '../util/crc32.dart';
import '../util/crc64.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import '../util/sha256.dart';

// The XZ specification can be found at https://tukaani.org/xz/xz-file-format.txt.

/// Checksum used for compressed data.
enum XZCheck { none, crc32, crc64, sha256 }

/// The most an uncompressed LZMA2 chunk can hold. Its length field is two
/// bytes wide
const _lzma2ChunkMax = 1 << 16;

/// Dictionary size written to the block header: stored chunks don't need a
/// dictionary, but decoders require one, and both encoders use the same value
/// so their output is identical
const xzDefaultDictionarySize = 0x800000;

/// LZMA2 dictionary size byte: size = (2 + low bit) << (remaining bits + 11),
/// with 40 meaning 4 GiB - 1.
int xzDictionarySizeValue(int dictionarySize) {
  if (dictionarySize == 0) {
    throw ArchiveException('Invalid dictionary size $dictionarySize');
  }
  if (dictionarySize == 0xffffffff) {
    return 40;
  }
  var mantissa = dictionarySize;
  var exponent = 0;
  while ((mantissa & 0x1) == 0 && mantissa > 3) {
    mantissa >>= 1;
    exponent++;
  }
  if ((mantissa != 2 && mantissa != 3) || exponent < 11 || exponent > 30) {
    throw ArchiveException('Invalid dictionary size $dictionarySize');
  }
  return ((exponent - 11) << 1) | (mantissa & 0x1);
}

/// Compress data using the xz format encoder.
/// This encoder only currently supports uncompressed data.
class XZEncoder {
  Uint8List encodeBytes(List<int> bytes, {XZCheck check = XZCheck.crc64}) {
    final input = InputMemoryStream(bytes);
    final output = OutputMemoryStream();
    encodeStream(input, output, check: check);
    return output.getBytes();
  }

  /// Alias for [encodeBytes], kept for backwards compatibility.
  List<int> encode(List<int> bytes, {XZCheck check = XZCheck.crc64}) =>
      encodeBytes(bytes, check: check);

  void encodeStream(InputStream input, OutputStream output,
      {XZCheck check = XZCheck.crc64}) {
    final held = output.byteOrder;
    output.byteOrder = ByteOrder.littleEndian;
    try {
      _encodeStream(input, output, check);
    } finally {
      output.byteOrder = held;
    }
  }

  void _encodeStream(InputStream input, OutputStream output, XZCheck check) {
    var flags = 0;
    switch (check) {
      case XZCheck.none:
        break;
      case XZCheck.crc32:
        flags |= 0x1;
        break;
      case XZCheck.crc64:
        flags |= 0x4;
        break;
      case XZCheck.sha256:
        flags |= 0xa;
        break;
    }

    _writeStreamHeader(output, flags: flags);

    final records = <_XZBlockSize>[];
    final inputLength = input.length;
    if (inputLength > 0) {
      final compressedLength = _writeBlock(output, input, streamFlags: flags);
      records.add(_XZBlockSize(compressedLength, inputLength));
    }

    var indexStart = output.length;
    _writeStreamIndex(output, records: records);
    var indexSize = output.length - indexStart;

    _writeStreamFooter(output, indexSize: indexSize, flags: flags);
    output.flush();
  }

  // Writes an XZ stream header to [output].
  void _writeStreamHeader(OutputStream output, {required int flags}) {
    // '\xfd7zXZ\x00'
    output.writeBytes([253, 55, 122, 88, 90, 0]);

    final header = OutputMemoryStream();
    header.writeByte(0); // Unused flags.
    header.writeByte(flags);

    final headerBytes = header.getBytes();
    output.writeBytes(headerBytes);
    output.writeUint32(getCrc32(headerBytes));
  }

  // Writes [data] to [output] in XZ block format.
  int _writeBlock(OutputStream output, InputStream input,
      {required int streamFlags,
      bool hasCompressedLength = false,
      bool hasUncompressedLength = false}) {
    final inputLength = input.length;
    final chunks = (inputLength + _lzma2ChunkMax - 1) ~/ _lzma2ChunkMax;
    final compressedLength = inputLength + chunks * 3 + 1;

    // Optionally write the compressed and uncompressed lengths.
    final blockLengths = OutputMemoryStream();
    if (hasCompressedLength) {
      _writeMultibyteInteger(blockLengths, compressedLength);
    }
    if (hasUncompressedLength) {
      _writeMultibyteInteger(blockLengths, inputLength);
    }

    // Block is encoded with one LZMA2 filter.
    final filters = <OutputStream>[];
    filters.add(_makeLZMA2Filter(xzDefaultDictionarySize));

    // Generate header.
    var headerLength = 6 + blockLengths.length;
    for (final filter in filters) {
      headerLength += filter.length;
    }
    while (headerLength % 4 != 0) {
      headerLength++;
    }
    var flags = 0;
    flags |= filters.length - 1;
    if (hasCompressedLength) {
      flags |= 0x40;
    }
    if (hasUncompressedLength) {
      flags |= 0x80;
    }
    final header = OutputMemoryStream();
    header.writeByte((headerLength ~/ 4) - 1);
    header.writeByte(flags);
    header.writeBytes(blockLengths.getBytes());
    for (final filter in filters) {
      header.writeBytes(filter.getBytes());
    }
    _writePadding(header);

    // Write header.
    var headerBytes = header.getBytes();
    var blockStart = output.length;
    output.writeBytes(headerBytes);
    output.writeUint32(getCrc32(headerBytes));

    // Write block data.
    var crc32 = 0;
    final crc64 = Crc64();
    final sha256 = Sha256();
    final start = input.position;
    Uint8List? buffer;
    try {
      // Covert data into LZMA2 format.
      for (var at = 0; at < inputLength; at += _lzma2ChunkMax) {
        final want = inputLength - at < _lzma2ChunkMax
            ? inputLength - at
            : _lzma2ChunkMax;
        var chunk = input.viewBytes(want);
        if (chunk == null) {
          buffer ??= Uint8List(_lzma2ChunkMax);
          final got = input.readInto(buffer, 0, want);
          if (got <= 0) {
            break;
          }
          chunk = Uint8List.sublistView(buffer, 0, got);
        }
        switch (streamFlags & 0xf) {
          case 0x01:
            crc32 = getCrc32(chunk, crc32);
          case 0x04:
            crc64.update(chunk);
          case 0x0a:
            sha256.update(chunk, 0, chunk.length);
        }
        _writeLZMA2UncompressedData(output, chunk, resetDictionary: at == 0);
      }
    } finally {
      input.setPosition(start);
    }
    _writeLZMA2EndMarker(output);
    var paddingLength = _writePadding(output, from: blockStart);

    // Write data checksum.
    var checkType = streamFlags & 0xf;
    switch (checkType) {
      case 0x00: // none
        break;
      case 0x01: // CRC32
        output.writeUint32(crc32);
        break;
      case 0x04: // CRC64
        output.writeBytes(crc64.bytes);
        break;
      case 0x0a: // SHA-256
        output.writeBytes(sha256.digest());
        break;
      default:
        throw 'Unknown check type $checkType';
    }

    return output.length - blockStart - paddingLength;
  }

  // Generate an LZMA2 filter.
  OutputStream _makeLZMA2Filter(int dictionarySize) {
    final id = 0x21;
    final propertiesLength = 1;

    final filter = OutputMemoryStream();
    _writeMultibyteInteger(filter, id);
    _writeMultibyteInteger(filter, propertiesLength);
    filter.writeByte(xzDictionarySizeValue(dictionarySize));

    return filter;
  }

  // Write [data] to [output] in uncompressed LZMA2 format. A chunk holds its
  // length in 16 bits, so longer data is written in 64 KiB chunks
  void _writeLZMA2UncompressedData(OutputStream output, Uint8List data,
      {bool resetDictionary = true}) {
    var at = 0;
    var reset = resetDictionary;
    do {
      final take =
          data.length - at < _lzma2ChunkMax ? data.length - at : _lzma2ChunkMax;
      // Reset the dictionary on the first chunk, carry it on after that
      output.writeByte(reset ? 1 : 2);
      output.writeByte(((take - 1) >> 8) & 0xff);
      output.writeByte((take - 1) & 0xff);
      output.writeBytes(Uint8List.sublistView(data, at, at + take));
      at += take;
      reset = false;
    } while (at < data.length);
  }

  // Write an LZMA2 end marker to [output].
  void _writeLZMA2EndMarker(OutputStream output) {
    output.writeByte(0);
  }

  // Write the XZ stream index for [records] to [output].
  void _writeStreamIndex(OutputStream output,
      {required List<_XZBlockSize> records}) {
    final index = OutputMemoryStream();

    // Index indicator.
    index.writeByte(0);
    _writeMultibyteInteger(index, records.length);
    for (var record in records) {
      _writeMultibyteInteger(index, record.unpaddedLength);
      _writeMultibyteInteger(index, record.uncompressedLength);
    }
    _writePadding(index);

    final indexBytes = index.getBytes();
    output.writeBytes(indexBytes);
    output.writeUint32(getCrc32(indexBytes));
  }

  // Write an XZ stream footer to [output].
  void _writeStreamFooter(OutputStream output,
      {required int indexSize, required int flags}) {
    final footer = OutputMemoryStream();
    footer.writeUint32((indexSize ~/ 4) - 1);
    footer.writeByte(0); // Unused flags.
    footer.writeByte(flags);

    final footerBytes = footer.getBytes();
    output.writeUint32(getCrc32(footerBytes));
    output.writeBytes(footerBytes);

    // 'YZ'
    output.writeBytes([89, 90]);
  }

  // Write [value] to output in multi-byte format: seven bits a byte, the
  // lowest first, with the top bit set on every byte but the last
  void _writeMultibyteInteger(OutputStream output, int value) {
    var left = value;
    while (left >= 0x80) {
      output.writeByte(0x80 | (left & 0x7f));
      left >>= 7;
    }
    output.writeByte(left);
  }

  // Add empty bytes to make [output] after [from] align to a 32 bit boundary.
  int _writePadding(OutputStream output, {int from = 0}) {
    var length = 0;
    while ((output.length - from) % 4 != 0) {
      output.writeByte(0);
      length++;
    }
    return length;
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

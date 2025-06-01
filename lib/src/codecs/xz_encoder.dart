import 'dart:typed_data';

import '../util/crc32.dart';
import '../util/crc64.dart';
import '../util/encryption.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';

// The XZ specification can be found at https://tukaani.org/xz/xz-file-format.txt.

/// Checksum used for compressed data.
enum XZCheck { none, crc32, crc64, sha256 }

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
    final data = input.toUint8List();
    // Covert data into LZMA2 format.
    final lzma2 = OutputMemoryStream();
    _writeLZMA2UncompressedData(lzma2, data);
    _writeLZMA2EndMarker(lzma2);
    final compressedLength = lzma2.length;

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
    filters.add(_makeLZMA2Filter(0x800000));

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
    output.writeBytes(lzma2.getBytes());
    var paddingLength = _writePadding(output);

    // Write data checksum.
    var checkType = streamFlags & 0xf;
    switch (checkType) {
      case 0x00: // none
        break;
      case 0x01: // CRC32
        output.writeUint32(getCrc32(data));
        break;
      case 0x04: // CRC64
        output.writeUint64(getCrc64(data));
        break;
      case 0x0a: // SHA-256
        output.writeBytes(SHA256Digest().process(data));
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
    filter.writeByte(_getDictionarySizeValue(dictionarySize));

    return filter;
  }

  // Write [data] to [output] in uncompressed LZMA2 format.
  void _writeLZMA2UncompressedData(OutputStream output, Uint8List data,
      {bool resetDictionary = true}) {
    // Reset dictionary and uncompressed data.
    output.writeByte(resetDictionary ? 1 : 2);

    final inputLength = data.length;
    // Length.
    output.writeByte(((inputLength - 1) >> 8) & 0xff);
    output.writeByte((inputLength - 1) & 0xff);

    // Uncompressed data.
    output.writeBytes(data);
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

  // Write [value] to output in multi-byte format.
  void _writeMultibyteInteger(OutputStream output, int value) {
    var shift = 0;
    while (value >> (shift + 7) != 0) {
      shift += 7;
    }
    while (shift > 0) {
      output.writeByte(0x80 | (value >> shift) & 0x7f);
      shift -= 7;
    }
    output.writeByte(value & 0x7f);
  }

  // Add empty bytes to make [output] align to a 32 bit boundary.
  int _writePadding(OutputStream output) {
    var length = 0;
    while (output.length % 4 != 0) {
      output.writeByte(0);
      length++;
    }
    return length;
  }

  // Calculate the encoded value for [dictionarySize].
  int _getDictionarySizeValue(int dictionarySize) {
    if (dictionarySize == 0) {
      throw 'Invalid dictionary size $dictionarySize';
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
      throw 'Invalid dictionary size $dictionarySize';
    }
    return ((exponent - 11) << 1) | (mantissa & 0x1);
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

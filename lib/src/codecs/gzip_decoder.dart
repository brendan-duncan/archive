import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/crc32.dart';
import '../util/input_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/output_stream.dart';
import 'zlib/inflate.dart';
import 'zlib/gzip_flag.dart';

/// Decompress data with the gzip format decoder.
class GZipDecoder {
  Uint8List decode(Uint8List data, {bool verify = false}) {
    return decodeStreamBytes(InputMemoryStream(data), verify: verify);
  }

  void decodeStream(InputStream input, OutputStream output) {
    _readHeader(input);
    Inflate.stream(input, output: output);
    output.flush();
  }

  Uint8List decodeStreamBytes(InputStream input, {bool verify = false}) {
    _readHeader(input);

    // Inflate
    final buffer = Inflate.stream(input).getBytes();

    if (verify) {
      final crc = input.readUint32();
      final computedCrc = getCrc32(buffer);
      if (crc != computedCrc) {
        throw ArchiveException('Invalid CRC checksum');
      }

      final size = input.readUint32();
      if (size != buffer.length) {
        throw ArchiveException('Size of decompressed file not correct');
      }
    }

    return buffer;
  }

  void _readHeader(InputStream input) {
    // The GZip format has the following structure:
    // Offset   Length   Contents
    // 0      2 bytes  magic header  0x1f, 0x8b (\037 \213)
    // 2      1 byte   compression method
    //                  0: store (copied)
    //                  1: compress
    //                  2: pack
    //                  3: lzh
    //                  4..7: reserved
    //                  8: deflate
    // 3      1 byte   flags
    //                  bit 0 set: file probably ascii text
    //                  bit 1 set: continuation of multi-part gzip file, part number present
    //                  bit 2 set: extra field present
    //                  bit 3 set: original file name present
    //                  bit 4 set: file comment present
    //                  bit 5 set: file is encrypted, encryption header present
    //                  bit 6,7:   reserved
    // 4      4 bytes  file modification time in Unix format
    // 8      1 byte   extra flags (depend on compression method)
    // 9      1 byte   OS type
    // [
    //        2 bytes  optional part number (second part=1)
    // ]?
    // [
    //        2 bytes  optional extra field length (e)
    //       (e)bytes  optional extra field
    // ]?
    // [
    //          bytes  optional original file name, zero terminated
    // ]?
    // [
    //          bytes  optional file comment, zero terminated
    // ]?
    // [
    //       12 bytes  optional encryption header
    // ]?
    //          bytes  compressed data
    //        4 bytes  crc32
    //        4 bytes  uncompressed input size modulo 2^32

    final signature = input.readUint16();
    if (signature != GZipFlag.signature) {
      throw ArchiveException('Invalid GZip Signature');
    }

    final compressionMethod = input.readByte();
    if (compressionMethod != GZipFlag.deflate) {
      throw ArchiveException('Invalid GZip Compression Method');
    }

    final flags = input.readByte();
    /*int fileModTime =*/ input.readUint32();
    /*int extraFlags =*/ input.readByte();
    /*int osType =*/ input.readByte();

    if (flags & GZipFlag.extra != 0) {
      final t = input.readUint16();
      input.readBytes(t);
    }

    if (flags & GZipFlag.name != 0) {
      input.readString();
    }

    if (flags & GZipFlag.comment != 0) {
      input.readString();
    }

    // just throw away for now
    if (flags & GZipFlag.hcrc != 0) {
      input.readUint16();
    }
  }
}

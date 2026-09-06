import 'dart:typed_data';

import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';
import '_zlib_decoder_web.dart';
import 'gzip_flag.dart';
import 'inflate.dart';

const platformGZipDecoder = _GZipDecoder();

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  const _GZipDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false}) {
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(data), output, verify: verify, raw: raw);
    return output.getBytes();
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false}) {
    var members = 0;
    while (!input.isEOS) {
      final startPos = input.position;
      if (!_readHeader(input)) {
        if (members != 0) {
          // Bytes after a member that do not begin another one. The stream
          // does not end where it says it does, so it is not whole.
          return false;
        }
        // Fall back to ZLib if there is no GZip header. This is to make it
        // consistent with dart's native library behavior.
        input.position = startPos;
        return platformZLibDecoder.decodeStream(input, output,
            verify: verify, raw: raw);
      }
      final memberStart = output.length;
      Inflate.stream(input, output: output);

      // A member cut short before its trailer would otherwise decode to a
      // short result and be reported as a success, which is a truncated
      // archive silently losing files.
      if (input.length < 8) {
        return false;
      }
      /*final crc =*/ input.readUint32();
      final size = input.readUint32();

      output.flush();

      // The trailer records the member's own uncompressed length modulo 2^32,
      // so it is checked against what this member wrote rather than against
      // the whole output, which several members share.
      if ((output.length - memberStart) % 0x100000000 != size) {
        return false;
      }
      members++;
    }

    return members != 0;
  }

  bool _readHeader(InputStream input) {
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

    // The fixed part of the header is ten bytes, and the reads below are
    // unchecked, so anything shorter is rejected here rather than as a
    // RangeError out of the middle of them.
    if (input.length < 10) {
      return false;
    }

    final signature = input.readUint16();
    if (signature != GZipFlag.signature) {
      return false;
      //throw ArchiveException('Invalid GZip Signature');
    }

    final compressionMethod = input.readByte();
    if (compressionMethod != GZipFlag.deflate) {
      return false;
      //throw ArchiveException('Invalid GZip Compression Method');
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

    return true;
  }
}

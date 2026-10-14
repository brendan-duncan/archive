import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/byte_order.dart';
import '../../util/chunked_sink.dart';
import '../../util/crc32.dart';
import '../../util/decode_guard.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_inflate_chunk_decoder.dart';
import '_zlib_decoder_base.dart';
import '_zlib_decoder_web.dart';
import '_zlib_encoder_base.dart';
import 'gzip_flag.dart';
import 'inflate.dart';

const platformGZipDecoder = _GZipDecoder();
const nativeGZipDecoder = _GZipDecoder(true);

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  final bool _verifyHeader;

  const _GZipDecoder([this._verifyHeader = false]);

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    final output = OutputMemoryStream();
    decodeStream(InputMemoryStream(data), output,
        verify: verify, raw: raw, throwOnError: throwOnError);
    return output.getBytes();
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    final held = input.byteOrder;
    input.byteOrder = ByteOrder.littleEndian;
    // Apple gzip and Python gzip decode members with reserved FLG bits or wrong
    // FHCRC, so rejecting them without flags loses data. We check header like
    // zlib only with verify or throwOnError
    final strict = _verifyHeader || verify || throwOnError;
    try {
      return guardDecode('gzip', verify, throwOnError,
          () => _decode(input, output, verify, raw, strict));
    } finally {
      input.byteOrder = held;
    }
  }

  @override
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      InputDecodeStream(InflateChunkDecoder(
          input, raw ? InflateFormat.raw : InflateFormat.gzip,
          verify: verify));

  bool _decode(InputStream input, OutputStream output, bool verify, bool raw,
      bool strict) {
    var members = 0;
    while (!input.isEOS) {
      final startPos = input.position;
      if (!_readHeader(input, strict)) {
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
      // Damage inside the deflate data stops the inflate short, and is caught
      // by the trailer checks below
      var sum = 0;
      final checked = verify
          ? (SinkOutputStream(ZLibOutputSink(output))
            ..watch = (bytes) => sum = getCrc32(bytes, sum))
          : null;
      final inflate =
          Inflate.stream(input, output: checked ?? output, throwOnError: true);
      checked?.flush();
      if (!inflate.isFinished) {
        return false;
      }

      // A member cut short before its trailer would otherwise decode to a
      // short result and be reported as a success, which is a truncated
      // archive silently losing files.
      if (input.length < 8) {
        return false;
      }
      final crc = input.readUint32();
      final size = input.readUint32();

      output.flush();

      // The trailer records the member's own uncompressed length modulo 2^32,
      // so it is checked against what this member wrote rather than against
      // the whole output, which several members share.
      if ((output.length - memberStart) % 0x100000000 != size) {
        return false;
      }

      // The length above says nothing about the bytes. A streamed output cannot
      // be read back, so its checksum is summed while writing, in pieces since
      // a member can be larger than memory
      if (verify && sum != crc) {
        throw ArchiveChecksumException('Invalid gzip checksum');
      }
      members++;
    }

    return members != 0;
  }

  bool _readHeader(InputStream input, bool strict) {
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

    final headerStart = input.position;
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
    if (strict && flags & 0xe0 != 0) {
      return false;
    }
    /*int fileModTime =*/ input.readUint32();
    /*int extraFlags =*/ input.readByte();
    /*int osType =*/ input.readByte();

    // The header sizes these itself, so a damaged one can point past the end
    // of the input
    if (flags & GZipFlag.extra != 0) {
      if (input.length < 2) {
        return false;
      }
      final t = input.readUint16();
      if (input.length < t) {
        return false;
      }
      input.readBytes(t);
    }

    if (flags & GZipFlag.name != 0) {
      if (!_skipString(input)) {
        return false;
      }
    }

    if (flags & GZipFlag.comment != 0) {
      if (!_skipString(input)) {
        return false;
      }
    }

    if (flags & GZipFlag.hcrc != 0) {
      if (input.length < 2) {
        return false;
      }
      if (strict) {
        final expected = input.readUint16();
        final header = input.subset(
            position: headerStart, length: input.position - headerStart - 2);
        var checksum = 0;
        while (!header.isEOS) {
          final count = header.length < 8192 ? header.length : 8192;
          checksum = getCrc32(header.readBytes(count).toUint8List(), checksum);
        }
        if (checksum & 0xffff != expected) {
          throw ArchiveException('Invalid gzip header checksum');
        }
      } else {
        // just throw away for now
        input.readUint16();
      }
    }

    return true;
  }

  // False if the string never terminates
  bool _skipString(InputStream input) {
    while (!input.isEOS) {
      if (input.readByte() == 0) {
        return true;
      }
    }
    return false;
  }
}

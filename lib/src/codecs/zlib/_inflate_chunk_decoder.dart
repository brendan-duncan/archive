import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'gzip_flag.dart';
import 'inflate.dart';

/// The framing around the deflate data.
enum InflateFormat { gzip, zlib, raw }

/// Decodes gzip, zlib or raw deflate data with the Dart [Inflate], a deflate
/// block at a time.
///
/// A gzip member's CRC and a zlib stream's Adler-32 are checked only with
/// [verify]. The output goes into a window that may have slid past the start
/// of the member by the time its trailer is read, so the checksum is updated
/// after each deflate block. The length in the gzip trailer is always
/// checked, which catches truncation.
class InflateChunkDecoder implements ChunkDecoder {
  final InputStream input;
  InflateFormat format;
  final bool verify;

  Inflate? _inflate;
  int _members = 0;
  int _memberStart = 0;
  int _check = 0;
  _State _state = _State.header;

  InflateChunkDecoder(this.input, this.format, {this.verify = false});

  /// A match in deflate can reach back 32 KB.
  @override
  int get history => 32768;

  @override
  bool decodeChunk(OutputStream output) {
    switch (_state) {
      case _State.header:
        if (input.isEOS) {
          if (_members == 0 && format != InflateFormat.raw) {
            throw ArchiveException(
                'Empty input is not a ${format.name} stream');
          }
          _state = _State.done;
          return false;
        }
        if (format == InflateFormat.gzip) {
          final start = input.position;
          if (!_readGZipHeader()) {
            if (_members != 0) {
              throw ArchiveException('Data after the last gzip member');
            }
            // Fall back to zlib if there is no gzip header, to be consistent
            // with the native library.
            input.position = start;
            format = InflateFormat.zlib;
          }
        }
        if (format == InflateFormat.zlib) {
          _readZLibHeader();
        }
        _memberStart = output.length;
        _check = format == InflateFormat.zlib ? 1 : 0;
        _inflate = Inflate.lazy(input, output: output);
        _state = _State.blocks;
        return true;

      case _State.blocks:
        final before = output.length;
        if (!_inflate!.inflateBlock()) {
          _state = _State.trailer;
        }
        if (verify && output.length > before) {
          final block = output.subset(before);
          if (format == InflateFormat.gzip) {
            _check = getCrc32(block, _check);
          } else if (format == InflateFormat.zlib) {
            _check = getAdler32(block, _check);
          }
        }
        return true;

      case _State.trailer:
        if (format == InflateFormat.gzip) {
          if (input.length < 8) {
            throw ArchiveException('Truncated gzip stream');
          }
          final crc = input.readUint32();
          final size = input.readUint32();
          if ((output.length - _memberStart) % 0x100000000 != size) {
            throw ArchiveException('gzip member length does not match');
          }
          if (verify && crc != _check) {
            throw ArchiveChecksumException('Invalid gzip checksum');
          }
        } else if (format == InflateFormat.zlib) {
          if (input.length < 4) {
            throw ArchiveException('Truncated zlib stream');
          }
          var adler = 0;
          for (var i = 0; i < 4; i++) {
            adler = (adler << 8) | input.readByte();
          }
          if (verify && adler != _check) {
            throw ArchiveChecksumException('Invalid zlib checksum');
          }
        }
        _members++;
        // A gzip stream is a series of members; the others are one stream.
        _state = format == InflateFormat.gzip ? _State.header : _State.done;
        return format == InflateFormat.gzip;

      case _State.done:
        return false;
    }
  }

  // False if the bytes at the read position are not a gzip header.
  bool _readGZipHeader() {
    if (input.length < 10) {
      return false;
    }
    if (input.readUint16() != GZipFlag.signature) {
      return false;
    }
    if (input.readByte() != GZipFlag.deflate) {
      return false;
    }
    final flags = input.readByte();
    input.readUint32(); // modification time
    input.readByte(); // extra flags
    input.readByte(); // os
    if (flags & GZipFlag.extra != 0) {
      if (input.length < 2) {
        return false;
      }
      final t = input.readUint16();
      if (input.length < t) {
        return false;
      }
      input.skip(t);
    }
    if (flags & GZipFlag.name != 0 && !_skipString()) {
      return false;
    }
    if (flags & GZipFlag.comment != 0 && !_skipString()) {
      return false;
    }
    if (flags & GZipFlag.hcrc != 0) {
      if (input.length < 2) {
        return false;
      }
      input.readUint16();
    }
    return true;
  }

  bool _skipString() {
    while (!input.isEOS) {
      if (input.readByte() == 0) {
        return true;
      }
    }
    return false;
  }

  void _readZLibHeader() {
    if (input.length < 2) {
      throw ArchiveException('Truncated zlib stream');
    }
    final cmf = input.readByte();
    final flg = input.readByte();
    if (cmf & 0xf != 8) {
      throw ArchiveException('Only deflate compression is supported');
    }
    if (((cmf * 256) + flg) % 31 != 0) {
      throw ArchiveException('Invalid zlib header');
    }
    if (flg & 0x20 != 0) {
      throw ArchiveException('zlib preset dictionaries are not supported');
    }
  }
}

enum _State { header, blocks, trailer, done }

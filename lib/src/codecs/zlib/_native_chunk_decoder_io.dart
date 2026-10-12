import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_output_stream_sink.dart';
import '_zlib_decoder_io.dart';
import '_zlib_encoder_base.dart';

/// Decodes gzip or zlib data through the native codec, a chunk of input at a
/// time.
///
/// The native codec checks the CRC and length of every gzip member whose
/// trailer it reaches, and rejects trailing bytes that do not begin another
/// member. What it does not reject is a member cut short before its trailer:
/// that decodes to a short result and reports success, which is a truncated
/// archive silently losing files. So the last eight bytes of the input are
/// kept as a sliding window and checked against the output at the end, see
/// [_checkTrailer].
class NativeChunkDecoder implements ChunkDecoder {
  final InputStream input;
  final bool gzip;
  final bool raw;

  final _sink = _ForwardSink();
  Sink<List<int>>? _codec;
  bool _closed = false;

  // The last eight bytes of the input, and how many of them are valid.
  final _trailer = Uint8List(8);
  int _trailerLength = 0;
  // Whether the input opened with the gzip signature, which decides whether
  // the trailer check applies at all.
  bool _isGZip = false;
  int _seen = 0;

  final bool verify;

  // dart:io reports wrong Adler-32 and damaged data with one message, so last
  // 4 bytes of zlib stream reach it only at end and we check Adler-32 here
  Uint8List _held = Uint8List(0);
  Uint8List _tail = Uint8List(0);

  NativeChunkDecoder(this.input,
      {required this.gzip, this.raw = false, this.verify = false}) {
    _sink.adler = verify && _holdsTrailer;
  }

  bool get _holdsTrailer => !gzip && !raw;

  @override
  int get history => 0;

  /// How many bytes have been written to the output so far.
  int get written => _sink.written;

  @override
  bool decodeChunk(OutputStream output) {
    if (_closed) {
      return false;
    }
    _sink.output = output;
    final codec = _codec ??= (gzip ? GZipCodec() : ZLibCodec(raw: raw))
        .decoder
        .startChunkedConversion(_sink);

    if (input.isEOS) {
      _closed = true;
      try {
        if (_holdsTrailer) {
          addTrailerUnchecked(codec, _held);
        }
        codec.close();
      } on FormatException catch (error) {
        throw _invalid(error);
      }
      output.flush();
      if (gzip) {
        _checkTrailer();
      } else if (_sink.adler) {
        if (_seen < 6) {
          throw ArchiveException('Truncated zlib stream');
        }
        checkZlibAdler(_tail, _sink.sum);
      }
      return false;
    }

    // Not clipped by the input's length, which a stream that decodes as it
    // is read can only give by decoding everything: a short read is what
    // every stream gives at its end.
    final chunk = input.readBytes(zlibChunkSize).toUint8List();
    if (chunk.isNotEmpty) {
      if (_seen == 0) {
        _isGZip = chunk[0] == 0x1f && (chunk.length < 2 || chunk[1] == 0x8b);
      } else if (_seen == 1) {
        _isGZip = _isGZip && chunk[0] == 0x8b;
      }
      _seen += chunk.length;
      final keep = min(8, chunk.length);
      if (keep < 8) {
        _trailer.setRange(0, 8 - keep, _trailer, keep);
      }
      _trailer.setRange(8 - keep, 8, chunk, chunk.length - keep);
      _trailerLength = min(8, _trailerLength + chunk.length);
    }
    try {
      if (_holdsTrailer) {
        _addHoldingTrailer(codec, chunk);
      } else {
        codec.add(chunk);
      }
    } on FormatException catch (error) {
      throw _invalid(error);
    }
    return true;
  }

  void _addHoldingTrailer(Sink<List<int>> codec, Uint8List chunk) {
    if (_sink.adler) {
      _tail = _lastBytes(_tail, chunk, zlibAdlerWindow + 4);
    }
    if (chunk.length < 4) {
      final joined = Uint8List.fromList([..._held, ...chunk]);
      final send = max(0, joined.length - 4);
      _addRange(codec, joined, send);
      _held = Uint8List.fromList(Uint8List.sublistView(joined, send));
      return;
    }
    if (_held.isNotEmpty) {
      codec.add(_held);
    }
    _addRange(codec, chunk, chunk.length - 4);
    _held = Uint8List.fromList(Uint8List.sublistView(chunk, chunk.length - 4));
  }

  static void _addRange(Sink<List<int>> codec, Uint8List bytes, int end) {
    if (codec is ByteConversionSink) {
      codec.addSlice(bytes, 0, end, false);
    } else {
      codec.add(Uint8List.sublistView(bytes, 0, end));
    }
  }

  static Uint8List _lastBytes(Uint8List tail, Uint8List chunk, int count) {
    if (chunk.length >= count) {
      return Uint8List.fromList(
          Uint8List.sublistView(chunk, chunk.length - count));
    }
    final keep = min(tail.length, count - chunk.length);
    return Uint8List(keep + chunk.length)
      ..setRange(0, keep, tail, tail.length - keep)
      ..setRange(keep, keep + chunk.length, chunk);
  }

  ArchiveException _invalid(FormatException error) =>
      ArchiveException('Invalid ${gzip ? 'gzip' : 'zlib'} data: '
          '${error.message}');

  // A member's last four bytes are its uncompressed length modulo 2^32, so
  // for a whole stream it cannot exceed what was written: equal for the one
  // member that a .gz or .tar.gz holds, less when members are concatenated.
  // In a truncated stream those four bytes are compressed data instead, and
  // land above the total unless they happen to read as a number the output
  // is long enough to cover, which for an output of n bytes is a chance of
  // n / 2^32. Past 4 GB of output the comparison stops saying anything,
  // since every value is then in range.
  //
  // None of this applies to an input that never had a gzip header: the
  // decoder underneath accepts a plain zlib stream too, and its trailer is
  // four bytes of Adler-32 that would fail this on sight.
  void _checkTrailer() {
    if (_seen == 0) {
      // Nothing at all is not a gzip stream, and not a zlib one either: the
      // shortest of those is two bytes.
      throw ArchiveException('Empty input is not a gzip stream');
    }
    if (!_isGZip) {
      return;
    }
    // 10 header + 2 deflate + 8 trailer. Below that the last eight bytes are
    // header, not the trailer read next
    if (_trailerLength < 8 || _seen < 20) {
      throw ArchiveException('Truncated gzip stream');
    }
    final declared = _trailer[4] |
        (_trailer[5] << 8) |
        (_trailer[6] << 16) |
        (_trailer[7] << 24);
    final written = _sink.written;
    if (written < 0x100000000 && declared > written) {
      throw ArchiveException('Truncated gzip stream');
    }
  }
}

// Passes the codec's output chunks on to whichever stream the current call
// is decoding into.
class _ForwardSink implements Sink<List<int>> {
  OutputStream? output;
  int written = 0;
  bool adler = false;
  int sum = 1;

  @override
  void add(List<int> data) {
    output!.writeBytes(data);
    written += data.length;
    if (adler) {
      sum = getAdler32(data, sum);
    }
  }

  @override
  void close() {}
}

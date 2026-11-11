import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/decode_guard.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_native_chunk_decoder_io.dart';
import '_output_stream_sink.dart';
import '_zlib_decoder_base.dart';
import '_zlib_encoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false, bool? throwOnError}) {
    final strict = throwOnError ?? verify;
    var out = Uint8List(0);
    final partial = OutputMemoryStream();
    List<int>? input = data;
    guardDecode('zlib', verify, strict, () {
      final held = input!;
      input = null;
      final bytes = held is Uint8List ? held : Uint8List.fromList(held);
      final trailerLength = raw ? 0 : 4;
      if (!raw && bytes.length < trailerLength + 2) {
        return false;
      }
      final tail = verify && !raw
          ? bytes.sublist(max(0, bytes.length - 4 - zlibAdlerWindow))
          : null;
      final trailerAccepted = convertKeepingPartial(ZLibCodec(raw: raw).decoder,
          bytes, bytes.length - trailerLength, partial,
          trailer: bytes.sublist(bytes.length - trailerLength));
      out = partial.getBytes();
      if (verify && !raw) {
        checkZlibAdler(tail!, getAdler32(out), trailerAccepted);
      }
      return true;
    });
    if (partial.length > 0) {
      out = partial.getBytes();
    }
    if (out.length < out.buffer.lengthInBytes >> 1) {
      out = Uint8List.fromList(out);
    }
    return out;
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool? throwOnError}) {
    final strict = throwOnError ?? verify;
    return guardDecode('zlib', verify, strict,
        () => _decodeStream(input, output, verify, raw, strict));
  }

  @override
  InputStream decodeLazy(InputStream input,
          {bool verify = false, bool raw = false}) =>
      InputDecodeStream(
          NativeChunkDecoder(input, gzip: false, raw: raw, verify: verify));

  bool _decodeStream(InputStream input, OutputStream output, bool verify,
      bool raw, bool throwOnError) {
    // dart:io reports a wrong checksum and damaged data with one message, so
    // its verdict on the Adler-32 is dropped and we check it ourselves
    final trailerLength = raw ? 0 : 4;
    final seen = input.length;
    if (!raw && seen < trailerLength + 2) {
      return false;
    }
    final outSink = ZLibOutputSink(output);
    if (verify && !raw) {
      outSink
        ..value = 1
        ..update = getAdler32;
    }
    final inSink = ZLibCodec(raw: raw).decoder.startChunkedConversion(outSink);
    var left = seen - trailerLength;
    // File-backed reads need one reusable buffer to avoid per-chunk copies.
    final scratch = Uint8List(zlibChunkSize);
    while (left > 0) {
      final take = min(zlibChunkSize, left);
      final got = input.readInto(scratch, 0, take);
      if (got <= 0) {
        break;
      }
      // dart:io's chunked decoder processes add synchronously, so the
      // underlying bytes can be overwritten on the next iteration.
      inSink.add(Uint8List.sublistView(scratch, 0, got));
      left -= got;
    }
    final trailerAccepted = addTrailerUnchecked(
        inSink, input.readBytes(trailerLength).toUint8List());
    inSink.close();
    if (raw) {
      return true;
    }
    if (!verify) {
      return true;
    }
    final back = min(zlibAdlerWindow, seen - trailerLength - left);
    input.rewind(back + trailerLength);
    checkZlibAdler(input.readBytes(back + 4).toUint8List(), outSink.value,
        trailerAccepted);
    return true;
  }
}

const zlibAdlerWindow = 4096;

void checkZlibAdler(Uint8List tail, int sum, bool trailerAccepted) {
  for (var at = tail.length - 4; at >= 0; at--) {
    final adler = (tail[at] << 24) |
        (tail[at + 1] << 16) |
        (tail[at + 2] << 8) |
        tail[at + 3];
    if (sum == adler) {
      return;
    }
  }
  if (trailerAccepted) {
    throw ArchiveException(
        'zlib stream is truncated or followed by other data');
  }
  throw ArchiveChecksumException('Invalid zlib checksum');
}

import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
import '../util/chunked_sink.dart';
import '../util/decode_guard.dart';
import '../util/input_decode_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_chunked.dart';
import 'zstd/zstd_constants.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_frame_decoder.dart';
import 'zstd/zstd_window.dart';

export 'zstd/zstd_constants.dart' show zstdDefaultMaxWindowSize;

/// Decompress data with the zstd format decoder.
class ZstdDecoder {
  /// Frames declaring a window above this are rejected rather than allocated
  /// for, since the header is only as trustworthy as whoever wrote the file.
  /// The format permits up to 3.75 TB; the default matches the reference
  /// decoder's own ceiling
  final int maxWindowSize;

  /// Applied to every frame, whether or not the frame has a dictionary id.
  /// A frame with a dictionary id is rejected unless this dictionary has
  /// that id
  final ZstdDictionary? dictionary;

  /// Pass [dictionary] to decode frames compressed with one. It may be a
  /// dictionary in the zstd format, as `zstd --train` writes, or any other
  /// bytes, which are then used as raw content
  ZstdDecoder({int? maxWindowSize, List<int>? dictionary})
      : this.withDictionary(
            dictionary == null ? null : ZstdDictionary(dictionary),
            maxWindowSize: maxWindowSize);

  /// Takes a [ZstdDictionary] parsed once, so decoders can share it
  ZstdDecoder.withDictionary(this.dictionary, {int? maxWindowSize})
      : maxWindowSize = maxWindowSize ?? zstdDefaultMaxWindowSize {
    if (this.maxWindowSize < 1024) {
      throw ArgumentError.value(maxWindowSize, 'maxWindowSize',
          'Must be at least the 1 KB minimum window');
    }
  }

  /// Decompress the given [bytes] with the zstd format.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// {@macro archive.max_output_size.bytes}
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool throwOnError = false, int? maxOutputSize}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    // One frame decodes into its own buffer and is returned as a view of it.
    // Several would have to be joined afterwards, holding every frame and the
    // join at once, so they go through one sink instead
    if (maxOutputSize != null || _frameCount(bytes) > 1) {
      final sink = OutputMemoryStream();
      final total = uncompressedSize(bytes);
      if (total != null && total > 0) {
        var reserve = _affordable(total, bytes.length, zstdBlockMaximumSize);
        if (maxOutputSize != null && maxOutputSize < reserve) {
          reserve = maxOutputSize;
        }
        sink.reserve(reserve);
      }
      decodeLimited(
          sink,
          maxOutputSize,
          (output) => guardDecode('zstd', verify, throwOnError, () {
                _decode(bytes, verify, sink, null, output);
                return true;
              }));
      return _exact(sink.getBytes());
    }
    final parts = <Uint8List>[];
    guardDecode('zstd', verify, throwOnError, () {
      _decode(bytes, verify, null, parts);
      return true;
    });
    return parts.isEmpty ? Uint8List(0) : _exact(parts[0]);
  }

  static Uint8List _exact(Uint8List bytes) =>
      bytes.length < bytes.buffer.lengthInBytes >> 1
          ? Uint8List.fromList(bytes)
          : bytes;

  /// How many frames have content, without decoding any of them. Anything the
  /// scan cannot parse counts as one, which keeps the decode itself the
  /// only place that reports a malformed archive
  int _frameCount(Uint8List bytes) {
    var at = 0;
    var frames = 0;
    try {
      while (at + 4 <= bytes.length) {
        final magic = _uint32At(bytes, at);
        if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
          at += 8 + _uint32At(bytes, at + 4);
          continue;
        }
        if (magic != zstdMagic) {
          return 1;
        }
        final header =
            readFrameHeader(bytes, at + 4, bytes.length, maxWindowSize);
        at = _skipFrame(bytes, at + 4 + header.size, header);
        frames++;
        if (frames > 1) {
          return frames;
        }
      }
    } catch (_) {
      return 1;
    }
    return frames;
  }

  /// Decompress the given [input] with the zstd format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// {@macro archive.max_output_size.stream}
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool throwOnError = false, int? maxOutputSize}) {
    return decodeLimited(
        output,
        maxOutputSize,
        (output) => guardDecode('zstd', verify, throwOnError, () {
              _stream(input, output, verify);
              return true;
            }));
  }

  /// {@macro archive.decode_lazy}
  ///
  /// [verify] checks frame checksums, and a mismatch throws from the read that
  /// reaches the end of that frame.
  InputStream decodeLazy(InputStream input, {bool verify = false}) =>
      InputDecodeStream(ChunkedSinkDecoder(
          input,
          (output) => ZstdChunkedDecoder(output,
              verify: verify,
              dictionary: dictionary,
              maxWindowSize: maxWindowSize)));

  /// Reads the frames of [input] a block at a time, so neither the compressed
  /// side nor the decoded one is ever held whole
  void _stream(InputStream input, OutputStream output, bool verify) {
    Uint8List? scratch;
    var frames = 0;
    var skipped = 0;
    while (!input.isEOS) {
      if (input.length < 4) {
        throw ZstdFrameException('Trailing bytes are not a frame');
      }
      final magic = _uint32At(input.peekBytes(4).toUint8List(), 0);
      if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
        if (input.length < 8) {
          throw ZstdFrameException('Skippable frame header is truncated');
        }
        final size = _uint32At(input.peekBytes(8).toUint8List(), 4);
        if (input.length < 8 + size) {
          throw ZstdFrameException('Skippable frame is truncated');
        }
        input.skip(8 + size);
        skipped++;
        continue;
      }
      if (magic != zstdMagic) {
        throw ZstdFrameException('Not a zstd frame');
      }

      // The longest header is the magic, the descriptor, a window byte, four
      // bytes of dictionary id and eight of content size
      final ahead = input.length < 18 ? input.length : 18;
      final front = input.peekBytes(ahead).toUint8List();
      final header = readFrameHeader(front, 4, ahead, maxWindowSize);
      final dictionary = this.dictionary;
      if (header.dictionaryId != 0 &&
          (dictionary == null || dictionary.id != header.dictionaryId)) {
        throw ZstdFrameException(
            'Frame needs dictionary ${header.dictionaryId}');
      }
      input.skip(4 + header.size);

      final window = ZstdWindow(header.windowSize, output: output)
        ..emitEachBlock = output is LimitedOutputStream;
      if (dictionary != null && dictionary.content.isNotEmpty) {
        window.prime(dictionary.content);
      }
      // One block of compressed bytes plus its header. The decoder never needs
      // more of the input at once
      scratch ??= Uint8List(zstdBlockMaximumSize + 3);
      if (scratch.length < header.blockSizeMax + 3) {
        scratch = Uint8List(header.blockSizeMax + 3);
      }
      try {
        ZstdFrameDecoder().decodeBlocksFrom(
            input, window, header, verify, dictionary, scratch);
      } finally {
        window.finish();
      }
      frames++;
    }
    // An archive of nothing but skippable frames decodes to nothing, the way
    // the reference reads one. So only an empty input is a failure
    if (frames == 0 && skipped == 0) {
      throw ZstdFrameException('No frame: the input is empty');
    }
  }

  /// Reads the size the frames declare, or null when any of them does not
  /// say. It is a claim by whoever wrote the archive, not a fact
  int? uncompressedSize(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var at = 0;
    var total = 0;
    try {
      while (at + 4 <= bytes.length) {
        final magic = _uint32At(bytes, at);
        if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
          at += 8 + _uint32At(bytes, at + 4);
          continue;
        }
        if (magic != zstdMagic) {
          return null;
        }
        final header =
            readFrameHeader(bytes, at + 4, bytes.length, maxWindowSize);
        final size = header.contentSize;
        if (size == null) {
          return null;
        }
        total += size;
        // Only the header was read, so the block headers have to be read to
        // find where the next frame starts
        at = _skipFrame(bytes, at + 4 + header.size, header);
      }
    } catch (_) {
      return null;
    }
    return total;
  }

  void _decode(Uint8List bytes, bool verify, OutputMemoryStream? output,
      List<Uint8List>? parts,
      [OutputStream? target]) {
    final end = bytes.length;
    var at = 0;
    if (end == 0) {
      throw ZstdFrameException('No frame: the input is empty');
    }
    while (at < end) {
      if (at + 4 > end) {
        throw ZstdFrameException('Trailing bytes are not a frame');
      }
      final magic = _uint32At(bytes, at);
      if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
        if (at + 8 > end) {
          throw ZstdFrameException('Skippable frame header is truncated');
        }
        final size = _uint32At(bytes, at + 4);
        if (at + 8 + size > end) {
          throw ZstdFrameException('Skippable frame is truncated');
        }
        at += 8 + size;
        continue;
      }
      if (magic != zstdMagic) {
        throw ZstdFrameException('Not a zstd frame');
      }

      final header = readFrameHeader(bytes, at + 4, end, maxWindowSize);
      final dictionary = this.dictionary;
      if (header.dictionaryId != 0 &&
          (dictionary == null || dictionary.id != header.dictionaryId)) {
        throw ZstdFrameException(
            'Frame needs dictionary ${header.dictionaryId}');
      }
      final prefix = dictionary?.content.length ?? 0;
      final window = ZstdWindow(header.windowSize, output: target ?? output)
        ..emitEachBlock = target is LimitedOutputStream;
      final size = header.contentSize;
      if (output == null && size != null && size > 0) {
        // The scratch a block needs above its own output has to be part of the
        // one allocation, or the last blocks grow the buffer and copy it all
        window.reserve(prefix +
            _affordable(size, end - at - 4 - header.size, header.blockSizeMax) +
            header.blockReserve);
      }
      if (prefix > 0) {
        window.prime(dictionary!.content);
      }
      final frame = ZstdFrameDecoder();
      at += 4 + header.size;
      try {
        at += frame.decodeBlocks(
            bytes, at, end, window, header, verify, dictionary);
      } finally {
        if (output != null) {
          window.finish();
        } else {
          parts!.add(Uint8List.sublistView(
              window.buffer, window.origin, window.position));
        }
      }
    }
  }

  /// Reads the block headers of a frame whose header ends at [start] and
  /// returns where the frame ends
  int _skipFrame(Uint8List bytes, int start, ZstdFrameHeader header) {
    var at = start;
    while (true) {
      if (at + 3 > bytes.length) {
        throw ZstdFrameException('Block header is truncated');
      }
      final block = bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      final type = (block >> 1) & 3;
      final size = block >> 3;
      at += 3 + (type == zstdBlockRle ? 1 : size);
      if (block & 1 != 0) {
        break;
      }
    }
    return at + (header.hasChecksum ? 4 : 0);
  }

  /// A frame can declare any content size, so the size alone reserves no
  /// memory. A block costs three bytes of header and yields at most
  /// [blockSizeMax], so [remaining] bytes of input cannot produce more than
  /// this whatever the header declares. Above that the buffer grows as needed
  static int _affordable(int declared, int remaining, int blockSizeMax) {
    var ceiling = ((remaining + 2) ~/ 3) * blockSizeMax;
    // 1 MB of RLE blocks can claim 43 GB, and allocating it threw
    // OutOfMemoryError that throwOnError: false does not catch, so
    // reservation stops at 256 MB as in ZstdDecoder of 4.5.1
    if (ceiling > _maxPreallocate) {
      ceiling = _maxPreallocate;
    }
    return declared < ceiling ? declared : ceiling;
  }

  static const _maxPreallocate = 256 * 1024 * 1024;

  static int _uint32At(Uint8List bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
}

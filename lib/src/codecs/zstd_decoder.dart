import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_decode_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_error.dart';
import 'zstd/zstd_frame_decoder.dart';

// The zstd format is specified in RFC 8878,
// https://datatracker.ietf.org/doc/html/rfc8878.

/// The default for [ZstdDecoder.maxWindowSize]: 128 MB, the same limit the
/// reference zstd decoder applies unless told otherwise.
const int zstdDefaultMaxWindowSize = 1 << 27;

/// Decompress data in the zstd (Zstandard) format.
///
/// Every frame in the input is decoded, one after another, as the reference
/// decoder does, and skippable frames are passed over.
class ZstdDecoder {
  /// The largest window, in bytes, a frame may ask for.
  ///
  /// The window is the history that matches may refer back into, and the
  /// decoder has to hold all of it. A frame names its own window size, so
  /// this bounds what a hostile input can make the decoder allocate. Frames
  /// written by `zstd --long` or at `--ultra` levels can need more than the
  /// default, up to 2 GB.
  final int maxWindowSize;

  final ZstdDictionary? _dictionary;

  /// Creates a decoder.
  ///
  /// Pass [dictionary] to decode frames compressed with one. It may be a
  /// dictionary in the zstd format, as `zstd --train` writes, or any other
  /// bytes, which are then used as raw content. Throws an [ArgumentError] if
  /// it starts like a zstd dictionary but is not a well formed one.
  ZstdDecoder(
      {List<int>? dictionary, this.maxWindowSize = zstdDefaultMaxWindowSize})
      : _dictionary = _parseDictionary(dictionary) {
    if (maxWindowSize < 0 || maxWindowSize > 0x80000000) {
      throw ArgumentError.value(
          maxWindowSize, 'maxWindowSize', 'Must be between 0 and 2 GB');
    }
  }

  static ZstdDictionary? _parseDictionary(List<int>? bytes) {
    if (bytes == null) {
      return null;
    }
    try {
      return ZstdDictionary(bytes);
    } on ZstdFormatError catch (e) {
      throw ArgumentError(
          'Malformed zstd dictionary: ${e.message}', 'dictionary');
    } on RangeError {
      throw ArgumentError('Truncated zstd dictionary', 'dictionary');
    }
  }

  /// Decompress the given [data] in the zstd format.
  ///
  /// A malformed or truncated input yields whatever was decoded before the
  /// failure, with nothing to say that it is not the whole thing. Set
  /// [throwOnError] to get an [ArchiveException] instead.
  ///
  /// [verify] checks the content checksum of each frame that has one, which
  /// catches damage that decodes without complaint. It changes only whether a
  /// failure is noticed, never what a successful decode returns.
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool throwOnError = false}) {
    // Sized up front from what the first frame declares, which saves growing
    // the buffer as the output arrives. The declaration is only as trustworthy
    // as the data, so above a ceiling it is not acted on.
    final size = _declaredSize(data);
    final output = OutputMemoryStream(
        size:
            size != null && size > 0 && size <= _maxPreallocate ? size : null);
    decodeStream(InputMemoryStream(data), output,
        verify: verify, throwOnError: throwOnError);
    return output.getBytes();
  }

  static const int _maxPreallocate = 256 * 1024 * 1024;

  // The content size the first frame declares, if the data starts with a
  // frame that declares one.
  static int? _declaredSize(List<int> d) {
    if (d.length < 6 ||
        d[0] != 0x28 ||
        d[1] != 0xb5 ||
        d[2] != 0x2f ||
        d[3] != 0xfd) {
      return null;
    }
    final descriptor = d[4];
    final singleSegment = descriptor & 0x20 != 0;
    var size = const [0, 2, 4, 8][descriptor >> 6];
    if (size == 0) {
      if (!singleSegment) {
        return null;
      }
      size = 1;
    }
    final pos =
        5 + (singleSegment ? 0 : 1) + const [0, 1, 2, 4][descriptor & 3];
    if (pos + size > d.length) {
      return null;
    }
    var value = 0;
    var scale = 1;
    for (var i = 0; i < size; i++) {
      value += d[pos + i] * scale;
      scale *= 256;
    }
    return size == 2 ? value + 256 : value;
  }

  /// Decompress the given [input] in the zstd format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// Returns false if the input is malformed or truncated, in which case
  /// [output] holds however much was decoded before the failure and should be
  /// discarded. Set [throwOnError] to get an [ArchiveException] instead; the
  /// partial data is in [output] either way.
  ///
  /// [verify] checks the content checksum of each frame that has one.
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool throwOnError = false}) {
    final decoder = _ZstdChunkDecoder(_frameDecoder(verify), input);
    try {
      while (decoder.decodeChunk(output)) {}
      return true;
    } on ArchiveException {
      if (throwOnError) {
        rethrow;
      }
      return false;
    }
  }

  /// Returns an [InputStream] that decompresses [input] as it is read.
  ///
  /// Nothing is decoded until the returned stream is read, and only a window
  /// of the decoded data is held in memory, so a multi-gigabyte `.zst` can
  /// be fed to another decoder, such as a tar decoder, without a temp file.
  /// The stream is read forwards: see [InputDecodeStream] for what that
  /// means. A malformed or truncated input throws an [ArchiveException] from
  /// the read that runs into it. [verify] is as for [decodeStream].
  InputStream decodeLazy(InputStream input, {bool verify = false}) =>
      InputDecodeStream(_ZstdChunkDecoder(_frameDecoder(verify), input));

  ZstdFrameDecoder _frameDecoder(bool verify) => ZstdFrameDecoder(
      maxWindowSize: maxWindowSize, dictionary: _dictionary, verify: verify);
}

/// Decodes a zstd input a block at a time, passing over skippable frames.
class _ZstdChunkDecoder implements ChunkDecoder {
  final ZstdFrameDecoder _decoder;
  final InputStream _input;
  int _frames = 0;
  bool _inFrame = false;

  _ZstdChunkDecoder(this._decoder, this._input);

  @override
  int get history => 0;

  @override
  bool decodeChunk(OutputStream output) {
    try {
      return _decodeChunk(output);
    } on ZstdFormatError catch (e) {
      throw ArchiveException('Invalid zstd data: ${e.message}');
    } on RangeError catch (e) {
      // An index out of range is malformed data that got past the checks.
      throw ArchiveException('Invalid zstd data: $e');
    }
  }

  bool _decodeChunk(OutputStream output) {
    if (_inFrame) {
      if (!_decoder.decodeBlock(_input, output)) {
        _inFrame = false;
      }
      return true;
    }
    if (_input.isEOS) {
      if (_frames == 0) {
        throw ZstdFormatError('No zstd frames');
      }
      return false;
    }
    if (_input.length < 4) {
      throw ZstdFormatError('Truncated frame header');
    }
    final magic = ZstdFrameDecoder.readLittleEndian(_input, 4);
    if (magic == zstdFrameMagic) {
      _decoder.startFrame(_input);
      _inFrame = true;
    } else if (magic >= zstdSkippableMagic && magic < zstdSkippableMagic + 16) {
      if (_input.length < 4) {
        throw ZstdFormatError('Truncated skippable frame');
      }
      final size = ZstdFrameDecoder.readLittleEndian(_input, 4);
      if (_input.length < size) {
        throw ZstdFormatError('Truncated skippable frame');
      }
      _input.skip(size);
    } else {
      throw ZstdFormatError(_frames == 0
          ? 'Not zstd data'
          : 'Unrecognized data after frame $_frames');
    }
    _frames++;
    return true;
  }
}

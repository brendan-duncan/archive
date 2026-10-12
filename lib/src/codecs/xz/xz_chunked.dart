import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/decode_guard.dart';
import '../../util/input_memory_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/sha256.dart';
import '../bcj_x86.dart';
import '../lzma/lzma_decoder.dart';
import '../xz_encoder.dart';
import 'xz_block_dispatch.dart';
import 'xz_index.dart';
import 'xz_multithread_options.dart';
import 'xz_parallel.dart';
import 'xz_stream_decoder.dart';

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class XzDecoderConverter extends ChunkedConverter {
  /// {@macro archive.xz.verify_default}
  final bool verify;

  /// `startChunkedConversion` cannot take this option. Its sink writes its
  /// output before it returns, and a worker answers later
  final XZMultithreadOptions<Object?>? multithread;

  const XzDecoderConverter({this.verify = true, this.multithread});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    if (multithread != null) {
      throw ArgumentError.value(
          multithread,
          'multithread',
          'Works through the converter bound to a stream only, since a sink owes '
              'its output before '
              'it returns');
    }
    return FailOnceSink(XzChunkedDecoder(
        sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
        verify: verify));
  }

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    final options = multithread;
    if (options == null) {
      return super.bind(stream);
    }
    return archiveStreamErrors(
        stream,
        (Stream<List<int>> source) => subscribedOnListen(source,
            (Stream<List<int>> source) => _bindMultithread(source, options)));
  }

  Stream<List<int>> _bindMultithread(
      Stream<List<int>> stream, XZMultithreadOptions<Object?> options) async* {
    final workers = options.workers;
    if (workers != null && workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
    }
    final budget = options.memoryBudget;
    if (budget != null && budget < 1) {
      throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
    }
    if (!xzIsolatesSupported) {
      // Not super.bind: that goes through startChunkedConversion, which
      // refuses the options this converter still carries
      yield* XzDecoderConverter(verify: verify)
          .bind(stream)
          .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError: (error, stack, sink) => sink
                ..addError(error, stack)
                ..close()));
      return;
    }
    yield* xzDecodeStreamMultithreaded(stream,
        verify: verify, workers: workers, memoryBudget: budget);
  }
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class XzCodec extends Codec<List<int>, List<int>> {
  /// {@macro archive.xz.verify_default}
  final bool verify;

  final XZCheck check;

  /// {@macro archive.yield_codecs_multithreaded_example}
  final XZMultithreadOptions<Object?>? multithread;

  const XzCodec(
      {this.verify = true, this.check = XZCheck.crc64, this.multithread});

  @override
  XzDecoderConverter get decoder =>
      XzDecoderConverter(verify: verify, multithread: multithread);

  @override
  XzEncoderConverter get encoder => XzEncoderConverter(check: check);
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
const xzCodec = XzCodec();

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
class XzChunkedDecoder extends ChunkedSink {
  /// {@macro archive.xz.verify_default}
  final bool verify;

  /// Takes the blocks that can be decoded elsewhere. The threaded stream
  /// decoder shares this through it rather than repeating it
  final XzBlockDispatch? _dispatch;

  /// Set while the parse waits for [_dispatch] to go idle
  /// before decoding a block
  bool get waitingForIdle => _waitingForIdle;
  var _waitingForIdle = false;

  /// {@macro archive.xz.max_dictionary_size}
  final int maxDictionarySize;

  XzChunkedDecoder(Sink<List<int>> output,
      {bool verify = true, int maxDictionarySize = xzDefaultMaxDictionarySize})
      : this._(output, verify, null, maxDictionarySize);

  XzChunkedDecoder._(
      super.output, this.verify, this._dispatch, this.maxDictionarySize) {
    _sink = SinkOutputStream(output);
  }

  // The LZMA decoder, the block header parse and the LZMA2 chunk rules are the
  // whole buffer decoder's, so the two cannot drift apart
  late final _xz = XZStreamDecoder(
      verify: verify,
      maxPreallocateSize: 0,
      maxDictionarySize: maxDictionarySize);

  LzmaDecoder get _decoder => _xz.decoder;
  late final SinkOutputStream _sink;

  /// Current parser state and how many bytes it still needs
  _Stage _stage = _Stage.streamHeader;

  /// Position within the current stream. Block and index padding is aligned to
  /// it
  var _streamStart = 0;
  var _streamFlags = 0;
  final _blocks = <_BlockSize>[];

  /// The block being decoded
  var _blockStart = 0;
  var _blockDataStart = 0;

  var _blockPadding = 0;
  var _paddingCount = 0;
  int? _declaredCompressedLength;
  int? _declaredUncompressedLength;
  var _dictionarySize = 0;
  var _x86Filter = false;
  var _x86StartOffset = 0;
  BcjX86OutputStream? _x86;

  /// The LZMA2 chunk being read
  var _chunkControl = 0;
  var _chunkLength = 0;

  /// Running check for the current block, updated as bytes come in instead
  /// of buffering the block
  var _blockCrc32 = 0;
  final _blockCrc64 = Crc64();
  final _blockSha256 = Sha256();
  var _blockLength = 0;

  void _foldCheck(Uint8List piece) {
    final checkType = _streamFlags & 0xf;
    if (checkType == 0x1) {
      _blockCrc32 = getCrc32(piece, _blockCrc32);
    } else if (checkType == 0x4) {
      _blockCrc64.update(piece);
    } else if (checkType == 0xa) {
      _blockSha256.update(piece, 0, piece.length);
    }
  }

  /// State for reading the index and comparing it with the
  /// blocks we actually decoded
  var _indexRecords = 0;
  var _indexRead = 0;
  var _indexStart = 0;
  var _indexSize = 0;
  var _indexCrc = 0;

  /// Offset where the current stream starts, since padding is aligned relative
  /// to the stream, not the whole input
  int get _streamPosition => consumed - _streamStart;

  @override
  void finish() {
    if (_stage != _Stage.streamPadding || available != 0) {
      throw ArchiveException('xz: unexpected end of archive');
    }
    if ((_paddingCount & 3) != 0) {
      throw ArchiveException(
          'xz: stream padding is not a multiple of four bytes');
    }
    _sink.flush();
  }

  /// Reads what has arrived, one field at a time, and returns as soon as a
  /// field is short. Every step commits only once it has all of its bytes, so
  /// the next call starts where this one stopped
  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.streamHeader:
          if (available < 12) {
            // Refused on the first byte that is not the magic rather than
            // waited on, since the input may stop sending without closing
            final seen = available < 6 ? available : 6;
            final head = view(seen);
            for (var i = 0; i < seen; i++) {
              if (head[i] != const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0][i]) {
                throw ArchiveException('xz: invalid stream header signature');
              }
            }
            return;
          }
          _readStreamHeader();
        case _Stage.blockOrIndex:
          if (available < 1) {
            return;
          }
          if (view(1)[0] == 0) {
            _indexStart = _streamPosition;
            _stage = _Stage.indexHeader;
          } else {
            _stage = _Stage.blockHeader;
          }
        case _Stage.blockHeader:
          final size = (view(1)[0] + 1) * 4;
          if (available < size) {
            return;
          }
          if (!_readBlockHeader(size)) {
            return;
          }
        case _Stage.chunkControl:
          if (available < 1) {
            return;
          }
          _readChunkControl();
        case _Stage.chunkHeader:
          if (!_readChunkHeader()) {
            return;
          }
        case _Stage.chunkBody:
          if (available < _chunkLength) {
            return;
          }
          _readChunkBody();
          if (unitAtATime) {
            return;
          }
        case _Stage.blockPadding:
          final pad = (4 - (_streamPosition & 3)) & 3;
          if (available < pad) {
            return;
          }
          final blockPad = view(pad);
          for (var i = 0; i < pad; i++) {
            if (blockPad[i] != 0) {
              throw ArchiveException('xz: invalid block padding');
            }
          }
          _blockPadding = pad;
          skip(pad);
          _stage = _Stage.blockCheck;
        case _Stage.blockCheck:
          final size = xzCheckSize(_streamFlags & 0xf);
          if (available < size) {
            return;
          }
          _readBlockCheck(size);
        case _Stage.indexHeader:
          if (!_readIndexHeader()) {
            return;
          }
        case _Stage.indexRecords:
          if (!_readIndexRecords()) {
            return;
          }
        case _Stage.indexPadding:
          final pad = (4 - ((_streamPosition - _indexStart) & 3)) & 3;
          if (available < pad) {
            return;
          }
          final indexPad = view(pad);
          for (var i = 0; i < pad; i++) {
            if (indexPad[i] != 0) {
              throw ArchiveException('xz: invalid stream index padding');
            }
          }
          _indexCrc = getCrc32(indexPad, _indexCrc);
          skip(pad);
          _stage = _Stage.indexCrc;
        case _Stage.indexCrc:
          if (available < 4) {
            return;
          }
          if (_readUint32() != _indexCrc) {
            throw ArchiveException('xz: invalid stream index CRC checksum');
          }
          _indexSize = _streamPosition - _indexStart;
          _stage = _Stage.streamFooter;
        case _Stage.streamFooter:
          if (available < 12) {
            return;
          }
          _readStreamFooter();
        case _Stage.streamPadding:
          // Padding is zeros in multiples of four, and what follows it is
          // another stream. Only the end of the input says which
          while (available > 0 && view(1)[0] == 0) {
            skip(1);
            _paddingCount++;
          }
          if (available == 0) {
            return;
          }
          if ((_paddingCount & 3) != 0) {
            throw ArchiveException(
                'xz: stream padding is not a multiple of four bytes');
          }
          _startStream();
      }
    }
  }

  int _readUint32() {
    final field = view(4);
    final value =
        field[0] | (field[1] << 8) | (field[2] << 16) | (field[3] << 24);
    skip(4);
    return value;
  }

  void _startStream() {
    _streamStart = consumed;
    _paddingCount = 0;
    _streamFlags = 0;
    _blocks.clear();
    _decoder.dictionaryCap = 0;
    _decoder.dictionaryLimit = 0;
    _decoder.reset(resetDictionary: true);
    _stage = _Stage.streamHeader;
  }

  void _readStreamHeader() {
    final magic = view(6);
    if (magic[0] != 253 ||
        magic[1] != 55 ||
        magic[2] != 122 ||
        magic[3] != 88 ||
        magic[4] != 90 ||
        magic[5] != 0) {
      throw ArchiveException('xz: invalid stream header signature');
    }
    skip(6);
    final flags = view(2);
    // Only the low 4 bits of the second byte are the check ID and everything
    // else is reserved, so if any reserved bit is set we don't know
    // how to read this stream
    if (flags[0] != 0 || flags[1] & 0xf0 != 0) {
      throw ArchiveException('xz: invalid stream flags');
    }
    _streamFlags = flags[1];
    final crc = getCrc32(flags);
    skip(2);
    if (_readUint32() != crc) {
      throw ArchiveException('xz: invalid stream header CRC checksum');
    }
    _stage = _Stage.blockOrIndex;
  }

  /// False while waiting for the rest of a block to send to a worker,
  /// or for workers to finish before decoding a block itself
  bool _readBlockHeader(int size) {
    _blockStart = _streamPosition;
    _xz.failureReason = null;
    if (!_xz.readBlockHeader(InputMemoryStream(view(size)), size)) {
      final message = 'xz: ${_xz.failureReason}';
      throw xzIsLimitFailure(_xz.failureReason)
          ? ArchiveLimitException(message)
          : ArchiveException(message);
    }
    _declaredCompressedLength = _xz.blockCompressedLength;
    _declaredUncompressedLength = _xz.blockUncompressedLength;
    _dictionarySize = _xz.blockDictionarySize;
    _x86Filter = _xz.blockHasX86;
    _x86StartOffset = _xz.blockX86StartOffset;

    final dispatch = _dispatch;
    if (dispatch != null) {
      _waitingForIdle = false;
      final compressed = _declaredCompressedLength;
      final uncompressed = _declaredUncompressedLength;
      // If a block claims more than the limit, sending it to a worker would
      // mean buffering the whole thing first, so we decode it here as it
      // streams in
      final limit = dispatch.maxBlockBytes;
      if (compressed != null &&
          uncompressed != null &&
          compressed <= limit &&
          uncompressed <= limit) {
        final checkSize = xzCheckSize(_streamFlags & 0xf);
        final total = size +
            compressed +
            ((4 - ((size + compressed) & 3)) & 3) +
            checkSize;
        if (available < total) {
          return false;
        }
        dispatch.block(Uint8List.fromList(view(total)), _streamFlags,
            uncompressed, _dictionarySize);
        // Worker won't let a block go past its declared sizes, so we
        // check the index against those
        _blocks.add(_BlockSize(size + compressed + checkSize, uncompressed));
        skip(total);
        _stage = _Stage.blockOrIndex;
        return true;
      }
      if (!dispatch.idle) {
        _waitingForIdle = true;
        return false;
      }
    }

    skip(size);

    _x86 = _x86Filter ? BcjX86OutputStream(_sink, _x86StartOffset) : null;
    _sink.reset();
    _blockCrc32 = 0;
    _blockCrc64.reset();
    _blockSha256.reset();
    _sink.watch = verify ? _foldCheck : null;
    _blockDataStart = _streamPosition;
    _xz.needDictionaryReset = true;
    _xz.needProperties = true;
    _stage = _Stage.chunkControl;
    return true;
  }

  void _readChunkControl() {
    _chunkControl = view(1)[0];
    if (_chunkControl == 0) {
      skip(1);
      _finishBlockData();
      return;
    }
    if (_chunkControl > 2 && _chunkControl < 0x80) {
      throw ArchiveException('xz: unknown LZMA2 control code $_chunkControl');
    }
    _stage = _Stage.chunkHeader;
  }

  /// Waits for the lengths, so the whole chunk goes to
  /// [XZStreamDecoder.readLZMA2Chunk] at once
  bool _readChunkHeader() {
    final need = _chunkControl < 0x80
        ? 3
        : ((_chunkControl >> 5) & 0x3) >= 2
            ? 6
            : 5;
    if (available < need) {
      return false;
    }
    final field = view(need);
    _chunkLength = _chunkControl < 0x80
        ? need + ((field[1] << 8) | field[2]) + 1
        : need + ((field[3] << 8) | field[4]) + 1;
    _stage = _Stage.chunkBody;
    return true;
  }

  void _readChunkBody() {
    _xz.failureReason = null;
    final done = _xz.readLZMA2Chunk(
        InputMemoryStream(view(_chunkLength)), _x86 ?? _sink, _dictionarySize);
    if (done == false) {
      throw ArchiveException('xz: ${_xz.failureReason}');
    }
    skip(_chunkLength);
    _stage = _Stage.chunkControl;
  }

  void _finishBlockData() {
    _x86?.finish();
    _x86 = null;
    _decoder.reset(resetDictionary: true);
    final compressed = _streamPosition - _blockDataStart;
    final uncompressed = _sink.written;
    final declaredCompressed = _declaredCompressedLength;
    if (declaredCompressed != null && declaredCompressed != compressed) {
      throw ArchiveException(
          "xz: compressed data doesn't match the length in the block header");
    }
    final declaredUncompressed = _declaredUncompressedLength;
    if (declaredUncompressed != null && declaredUncompressed != uncompressed) {
      throw ArchiveException(
          "xz: uncompressed data doesn't match the length in the block header");
    }
    _stage = _Stage.blockPadding;
  }

  void _readBlockCheck(int size) {
    final checkType = _streamFlags & 0xf;
    final field = view(size);

    // Check covers uncompressed data, so a filtered block is verified only
    // after its filters are reversed
    if (verify && checkType == 0x1) {
      final expected =
          field[0] | (field[1] << 8) | (field[2] << 16) | (field[3] << 24);
      if (_blockCrc32 != expected) {
        throw ArchiveChecksumException('xz: $xzCrc32Failed');
      }
    } else if (verify && checkType == 0x4) {
      if (!_blockCrc64.matches(field, 0)) {
        throw ArchiveChecksumException('xz: $xzCrc64Failed');
      }
    } else if (verify && checkType == 0xa) {
      final actual = _blockSha256.digest();
      for (var i = 0; i < 32; i++) {
        if (actual[i] != field[i]) {
          throw ArchiveChecksumException('xz: $xzSha256Failed');
        }
      }
    }
    skip(size);

    _blockLength = _sink.written;
    _sink.watch = null;
    // Flush the finished block now: input may stall without closing, and the
    // next worker's block is written after it
    _sink.flush();

    // Index unpadded size: header + compressed data + check, excluding padding
    _blocks.add(_BlockSize(
        _streamPosition - _blockStart - _blockPadding, _blockLength));
    _stage = _Stage.blockOrIndex;
  }

  bool _readIndexHeader() {
    final reader = _ByteReader(view(available), 0);
    reader.byte();
    final records = reader.tryMultibyte();
    if (records == null) {
      return false;
    }
    if (records != _blocks.length) {
      throw ArchiveException('xz: stream index block count mismatch');
    }
    _indexRecords = records;
    _indexRead = 0;
    _indexCrc = getCrc32(view(reader.at));
    skip(reader.at);
    _stage = _Stage.indexRecords;
    return true;
  }

  bool _readIndexRecords() {
    while (_indexRead < _indexRecords) {
      final reader = _ByteReader(view(available), 0);
      final unpadded = reader.tryMultibyte();
      if (unpadded == null) {
        return false;
      }
      final uncompressed = reader.tryMultibyte();
      if (uncompressed == null) {
        return false;
      }
      final block = _blocks[_indexRead];
      if (block.unpadded != unpadded) {
        throw ArchiveException('xz: stream index compressed length mismatch');
      }
      if (block.uncompressed != uncompressed) {
        throw ArchiveException('xz: stream index uncompressed length mismatch');
      }
      _indexCrc = getCrc32(view(reader.at), _indexCrc);
      skip(reader.at);
      _indexRead++;
    }
    _stage = _Stage.indexPadding;
    return true;
  }

  void _readStreamFooter() {
    final crc = _readUint32();
    final footer = view(6);
    if (getCrc32(footer) != crc) {
      throw ArchiveException('xz: invalid stream footer CRC checksum');
    }
    final backwardSize = ((footer[0] |
                (footer[1] << 8) |
                (footer[2] << 16) |
                (footer[3] << 24)) +
            1) *
        4;
    if (backwardSize != _indexSize) {
      throw ArchiveException('xz: stream footer has invalid index size');
    }
    if (footer[4] != 0) {
      throw ArchiveException('xz: invalid stream footer flags');
    }
    if (footer[5] != _streamFlags) {
      throw ArchiveException(
          "xz: stream footer flags don't match the header flags");
    }
    skip(6);
    final magic = view(2);
    if (magic[0] != 89 || magic[1] != 90) {
      throw ArchiveException('xz: invalid stream footer signature');
    }
    skip(2);
    _stage = _Stage.streamPadding;
  }
}

/// Reads the fields of a header out of a buffer that already holds it
class _ByteReader {
  final Uint8List _bytes;
  final int _end;
  int at;

  _ByteReader(this._bytes, this.at, [int? end]) : _end = end ?? _bytes.length;

  int byte() {
    if (at >= _end) {
      throw ArchiveException('xz: a header field is truncated');
    }
    return _bytes[at++];
  }

  /// Null when the bytes for it have not arrived. The index is read out of
  /// the bytes received so far
  int? tryMultibyte() {
    var value = 0;
    var multiplier = 1;
    for (var i = 0; i < 9; i++) {
      if (at + i >= _end) {
        return null;
      }
      final data = _bytes[at + i];
      value += (data & 0x7f) * multiplier;
      if (data & 0x80 == 0) {
        // liblzma vli_decoder.c takes only the shortest encoding
        if (data == 0 && i > 0) {
          throw ArchiveException('xz: invalid multibyte integer');
        }
        at += i + 1;
        return value;
      }
      multiplier *= 128;
    }
    throw ArchiveException('xz: invalid multibyte integer');
  }
}

class _BlockSize {
  final int unpadded;
  final int uncompressed;

  const _BlockSize(this.unpadded, this.uncompressed);
}

enum _Stage {
  streamHeader,
  blockOrIndex,
  blockHeader,
  chunkControl,
  chunkHeader,
  chunkBody,
  blockPadding,
  blockCheck,
  indexHeader,
  indexRecords,
  indexPadding,
  indexCrc,
  streamFooter,
  streamPadding,
}

/// {@macro archive.codecs.not_converter}
///
/// It stores the data rather than compressing it.
/// That is all `XZEncoder` does today
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class XzEncoderConverter extends ChunkedConverter {
  final XZCheck check;

  const XzEncoderConverter({this.check = XZCheck.crc64});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      FailOnceSink(XzChunkedEncoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          check: check));
}

/// Sink for [XzEncoderConverter] - buffers at most one LZMA2 chunk of input
/// regardless of archive size
class XzChunkedEncoder extends ChunkedSink {
  final XZCheck check;

  XzChunkedEncoder(super.output, {this.check = XZCheck.crc64});

  late final _out = SinkOutputStream(output);

  var _started = false;
  var _blockStarted = false;
  var _blockHeaderLength = 0;
  var _dataLength = 0;
  var _uncompressed = 0;
  var _crc32 = 0;
  final _crc64 = Crc64();
  final _sha256 = Sha256();

  int get _flags => switch (check) {
        XZCheck.none => 0,
        XZCheck.crc32 => 0x1,
        XZCheck.crc64 => 0x4,
        XZCheck.sha256 => 0xa,
      };

  @override
  void step() {
    while (available >= _chunkMax) {
      _writeChunk(_chunkMax);
    }
  }

  @override
  void finish() {
    if (available > 0) {
      _writeChunk(available);
    }
    _writeStreamHeader();
    if (_blockStarted) {
      _out.writeByte(0); // LZMA2 end marker
      _dataLength++;
      _writeBlockEnd();
    }
    _writeIndexAndFooter();
    _out.flush();
  }

  void _writeChunk(int count) {
    _writeStreamHeader();
    _writeBlockHeader();
    final data = view(count);
    _fold(data);
    // Uncompressed chunk: control 1 resets the dictionary,
    // 2 keeps the previous one
    _out
      ..writeByte(_uncompressed == 0 ? 1 : 2)
      ..writeByte(((count - 1) >> 8) & 0xff)
      ..writeByte((count - 1) & 0xff)
      ..writeBytes(data);
    _dataLength += count + 3;
    _uncompressed += count;
    skip(count);
  }

  void _fold(Uint8List piece) {
    switch (check) {
      case XZCheck.crc32:
        _crc32 = getCrc32(piece, _crc32);
      case XZCheck.crc64:
        _crc64.update(piece);
      case XZCheck.sha256:
        _sha256.update(piece, 0, piece.length);
      case XZCheck.none:
        break;
    }
  }

  void _writeStreamHeader() {
    if (_started) {
      return;
    }
    _started = true;
    _out.writeBytes([253, 55, 122, 88, 90, 0]);
    final header = Uint8List.fromList([0, _flags]);
    _out
      ..writeBytes(header)
      ..writeUint32(getCrc32(header));
  }

  /// The header has no lengths. A block is written before its size is known
  void _writeBlockHeader() {
    if (_blockStarted) {
      return;
    }
    _blockStarted = true;
    final filter = OutputMemoryStream()
      ..writeByte(0x21) // LZMA2
      ..writeByte(1) // one property byte
      ..writeByte(xzDictionarySizeValue(xzDefaultDictionarySize));
    var length = 6 + filter.length;
    while (length % 4 != 0) {
      length++;
    }
    final header = OutputMemoryStream()
      ..writeByte((length ~/ 4) - 1)
      ..writeByte(0) // one filter, no lengths
      ..writeBytes(filter.getBytes());
    while (header.length < length - 4) {
      header.writeByte(0);
    }
    final bytes = header.getBytes();
    _blockHeaderLength = length;
    _out
      ..writeBytes(bytes)
      ..writeUint32(getCrc32(bytes));
  }

  void _writeBlockEnd() {
    var padding = 0;
    while ((_blockHeaderLength + _dataLength + padding) % 4 != 0) {
      _out.writeByte(0);
      padding++;
    }
    var checkLength = 0;
    switch (check) {
      case XZCheck.none:
        break;
      case XZCheck.crc32:
        _out.writeUint32(_crc32);
        checkLength = 4;
      case XZCheck.crc64:
        _out.writeBytes(_crc64.bytes);
        checkLength = 8;
      case XZCheck.sha256:
        _out.writeBytes(_sha256.digest());
        checkLength = 32;
    }
    _blocks.add(
        _Record(_blockHeaderLength + _dataLength + checkLength, _uncompressed));
  }

  void _writeIndexAndFooter() {
    final index = OutputMemoryStream()
      ..writeByte(0)
      ..writeBytes(xzMultibyteInteger(_blocks.length));
    for (final record in _blocks) {
      index
        ..writeBytes(xzMultibyteInteger(record.unpadded))
        ..writeBytes(xzMultibyteInteger(record.uncompressed));
    }
    while (index.length % 4 != 0) {
      index.writeByte(0);
    }
    final indexBytes = index.getBytes();
    _out
      ..writeBytes(indexBytes)
      ..writeUint32(getCrc32(indexBytes));

    final footer = OutputMemoryStream()
      ..writeUint32(((indexBytes.length + 4) ~/ 4) - 1)
      ..writeByte(0)
      ..writeByte(_flags);
    final footerBytes = footer.getBytes();
    _out
      ..writeUint32(getCrc32(footerBytes))
      ..writeBytes(footerBytes)
      ..writeBytes([89, 90]);
  }

  final _blocks = <_Record>[];
}

/// Seven bits per byte, the lowest first
///
/// `>>` is a 32 bit operator on dart2js, where a block of 4 GiB or more came
/// out as the encoding of zero. The readers divide the same way
Uint8List xzMultibyteInteger(int value) {
  final bytes = <int>[];
  var left = value;
  while (left >= 0x80) {
    bytes.add(0x80 | (left & 0x7f));
    left ~/= 128;
  }
  bytes.add(left);
  return Uint8List.fromList(bytes);
}

/// Maximum size of one output chunk is 64 KiB, same as gzip and bzip2
const _chunkMax = 1 << 16;

class _Record {
  final int unpadded;
  final int uncompressed;

  const _Record(this.unpadded, this.uncompressed);
}

/// Returns [XzChunkedDecoder] that sends every block it can to [dispatch]
XzChunkedDecoder xzChunkedDecoderWithDispatch(
        Sink<List<int>> output, XzBlockDispatch dispatch,
        {required bool verify}) =>
    XzChunkedDecoder._(output, verify, dispatch, xzDefaultMaxDictionarySize);

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../../util/decode_guard.dart';
import '../../util/output_memory_stream.dart';
import '../../util/report_progress.dart';
import '../../util/xxh64.dart';
import 'zstd_block_decoder.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_frame_decoder.dart';
import 'zstd_frame_encoder.dart';
import 'zstd_level_params.dart';
import 'zstd_mt_frame_encoder.dart';
import 'zstd_mt_parallel.dart';
import 'zstd_multithread_options.dart';
import 'zstd_window.dart';

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.converters.encoder}
class ZstdCodec extends Codec<List<int>, List<int>> {
  /// Checks the XXH64 of every frame that has one
  final bool verify;

  /// What a frame may name to reach back into
  final ZstdDictionary? dictionary;

  /// Refuses a frame whose window is wider than this. It stops an archive from
  /// requesting an arbitrary allocation
  final int maxWindowSize;

  const ZstdCodec(
      {this.verify = true,
      this.dictionary,
      this.maxWindowSize = zstdDefaultMaxWindowSize,
      this.level = zstdDefaultLevel,
      this.frameChecksum = true,
      this.multithread,
      this.ultra = false});

  @override
  ZstdDecoderConverter get decoder => ZstdDecoderConverter(
      verify: verify, dictionary: dictionary, maxWindowSize: maxWindowSize);

  /// What [ZstdEncoderConverter.level] uses
  final int level;

  /// Whether a written frame has an XXH64 of its content
  final bool frameChecksum;

  /// {@macro archive.yield_codecs_multithreaded_example}
  final ZstdMultithreadOptions<Object?>? multithread;

  /// {@macro archive.zstd.ultra}
  final bool ultra;

  @override
  ZstdEncoderConverter get encoder => ZstdEncoderConverter(
      level: level,
      checksum: frameChecksum,
      multithread: multithread,
      dictionary: dictionary,
      ultra: ultra);
}

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.converters.encoder}
const zstdCodec = ZstdCodec();

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
class ZstdDecoderConverter extends ChunkedConverter {
  /// Checks the XXH64 of every frame that has one. On by default: a stream
  /// reader releases the compressed bytes before the check runs, so it cannot
  /// be run again later
  final bool verify;

  final ZstdDictionary? dictionary;
  final int maxWindowSize;

  const ZstdDecoderConverter(
      {this.verify = true,
      this.dictionary,
      this.maxWindowSize = zstdDefaultMaxWindowSize});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      FailOnceSink(ZstdChunkedDecoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          verify: verify,
          dictionary: dictionary,
          maxWindowSize: maxWindowSize));
}

/// {@macro archive.codecs.general}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class ZstdEncoderConverter extends ChunkedConverter {
  final int level;

  /// Whether the frame has an XXH64 of its content
  final bool checksum;

  /// `startChunkedConversion` cannot take this option. Its sink writes its
  /// output before it returns, and a worker answers later
  final ZstdMultithreadOptions<Object?>? multithread;

  /// Placed before the content, as [ZstdChunkedEncoder.dictionary] describes
  final ZstdDictionary? dictionary;

  /// {@macro archive.zstd.content_size}
  final int? contentSize;

  /// {@macro archive.zstd.ultra}
  final bool ultra;

  const ZstdEncoderConverter(
      {this.level = zstdDefaultLevel,
      this.checksum = true,
      this.multithread,
      this.dictionary,
      this.contentSize,
      this.ultra = false});

  int get _level => contentSize == null &&
          !ultra &&
          zstdEffectiveLevel(level) > _levelWithoutUltra
      ? _levelWithoutUltra
      : level;

  static const _levelWithoutUltra = 19;

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
    return FailOnceSink(ZstdChunkedEncoder(
        sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
        level: _level,
        checksum: checksum,
        dictionary: dictionary,
        contentSize: contentSize));
  }

  /// The dictionary as the reference sees it here, none where it is too short
  /// for `ZSTD_compress_insertDictionary` to take
  ZstdDictionary? get _encodeDictionary {
    final dict = dictionary;
    return dict != null && dict.usableForEncode ? dict : null;
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

  Stream<List<int>> _bindMultithread(Stream<List<int>> stream,
      ZstdMultithreadOptions<Object?> options) async* {
    checkZstdMultithreadOptions(options);
    final size = contentSize;
    if (size != null && size < 0) {
      throw ArgumentError.value(size, 'contentSize', 'Must not be negative');
    }
    // `ZSTD_CCtx_init_compressStream2` sets nbWorkers to 0 for pledged size up
    // to ZSTDMT_JOBSIZE_MIN, so threaded frame of such input would not match C
    // output, and we compress it with single threaded encoder
    if (size != null && size <= zstdMtJobSizeMin) {
      var consumed = 0;
      yield* ZstdEncoderConverter(
              level: level,
              checksum: checksum,
              dictionary: dictionary,
              contentSize: size)
          .bind(stream.map((chunk) {
        consumed += chunk.length;
        reportProgress(options.onProgress, consumed);
        return chunk;
      }));
      return;
    }
    final sized = size == null
        ? zstdMtSizeUnknown
        : size + (_encodeDictionary?.sourceSize ?? 0);
    final hash = Xxh64()..reset();
    var total = 0;
    final counted = stream.map((chunk) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      total += bytes.length;
      if (size != null && total > size) {
        throw ArchiveException('Input is longer than contentSize $size');
      }
      if (checksum) {
        hash.update(bytes, 0, bytes.length);
      }
      return bytes;
    });
    var failed = false;
    // The header is written with the first chunk, not up front: only then do
    // we know whether any input came, and an empty frame records its content
    // size instead of a window size.
    yield* zstdMtCompressStream(counted, _level,
        jobSize: options.jobSize,
        overlapLog: options.overlapLog,
        workers: options.workers ?? 0,
        cap: zstdMtWorkerCap(
            options.memoryBudget ?? zstdDefaultMemoryBudget,
            _level,
            sized,
            ZstdMtFrameEncoder.geometry(_level, sized,
                jobSize: options.jobSize, overlapLog: options.overlapLog)),
        dictionary: _encodeDictionary,
        size: sized,
        onProgress: options.onProgress, header: (empty) {
      final header = OutputMemoryStream();
      if (size != null && !empty) {
        writeZstdFrameHeader(
            header,
            size,
            checksum,
            zstdParamsForLevel(_level, sized).windowLog,
            _encodeDictionary?.id ?? 0);
        return header.getBytes();
      }
      writeZstdMtStreamHeader(
          header, checksum, _level, _encodeDictionary?.id ?? 0, empty);
      return header.getBytes();
    }).transform(
        StreamTransformer.fromHandlers(handleError: (error, trace, sink) {
      failed = true;
      sink.addError(archiveError(error, 'zstd: '), trace);
    }));
    if (!failed && size != null && total != size) {
      throw ArchiveException('Input is $total bytes, contentSize is $size');
    }
    // `yield*` continues after an error, so without this flag the checksum of
    // a failed frame is written after the error event
    if (checksum && !failed) {
      final out = OutputMemoryStream();
      writeZstdMtChecksum(out, hash.digestLow);
      yield out.getBytes();
    }
  }
}

/// Writes one zstd frame over data that arrives in pieces.
///
/// `ZSTD_compressStream2` fills its own buffer one block of input at a time and
/// lets the block splitter cut inside that one block, so a streamed archive
/// differs from the one the whole input would give. This does the same: it
/// gathers a block, then encodes it
class ZstdChunkedEncoder extends ChunkedSink {
  final int level;
  final bool checksum;

  /// Placed before the content so the first blocks can reach into it, and
  /// named in the frame header. The bytes are the ones
  /// `ZSTD_compress_usingDict` writes, not the ones `zstd -D` writes: the
  /// reference's streaming path goes through a cdict, which chooses
  /// differently
  final ZstdDictionary? dictionary;

  /// {@macro archive.zstd.content_size}
  final int? contentSize;

  /// A level is resolved here rather than at the first block, so a level this
  /// cannot work at is a mistake at the call, like every other setting
  ZstdChunkedEncoder(super.output,
      {int level = zstdDefaultLevel,
      this.checksum = true,
      this.dictionary,
      this.contentSize})
      : level = zstdEffectiveLevel(level) {
    if (contentSize != null && contentSize! < 0) {
      throw ArgumentError.value(
          contentSize, 'contentSize', 'Must not be negative');
    }
  }

  late final _out = SinkOutputStream(output);
  late final ZstdLevelParams _params = contentSize == null
      ? zstdParamsForLevel(level, _sizeUnknown)
      : zstdParamsForLevel(
          level, contentSize! + (_encodeDictionary?.sourceSize ?? 0));
  late final int _matchWindow = 1 << _params.windowLog;
  late final int _windowSize = contentSize == null
      ? _matchWindow
      : contentSize! < 1
          ? 1
          : (contentSize! < _matchWindow ? contentSize! : _matchWindow);
  late final int _blockSizeMax =
      _windowSize < zstdBlockMaximumSize ? _windowSize : zstdBlockMaximumSize;
  late final ZstdBlockEncoder _blocks =
      ZstdBlockEncoder(_blockSizeMax, _params);
  final _splitter = ZstdBlockSplitter();
  // The header is written on the first block. The first bytes have gone
  // through the checksum by then, so neither may be set up there
  final _rep = Uint32List(3)..setAll(0, zstdInitialRepeatOffsets);
  final _hash = Xxh64();

  /// The window and what a block needs beside it. It holds no more of the
  /// content than that
  late final Uint8List _buffer = _makeBuffer();
  var _at = 0;
  var _filled = 0;
  var _base = 0;
  var _savings = 0;
  var _started = false;

  /// How many bytes of content have been received. It gives the position of
  /// the reference's input ring
  var _content = 0;

  /// `inBuffSize`, the ring the reference gathers into. It passes one
  /// `blockSizeMax` to the compressor at a time and starts over once the next
  /// one would not fit, so it wraps on every multiple of this
  late final int _ring = _windowSize + _blockSizeMax;

  /// What the reference reads for a size it does not know. It picks the level
  /// row from this and leaves the window unclamped
  static const _sizeUnknown = 1099511627776;

  /// The dictionary as the reference sees it here. There is none where it is
  /// too short for `ZSTD_compress_insertDictionary` to take
  ZstdDictionary? get _encodeDictionary {
    final dict = dictionary;
    return dict != null && dict.usableForEncode ? dict : null;
  }

  /// Loads the dictionary before anything arrives: it sits at the front of the
  /// window, and the first block reaches into it
  void _prime() {
    final dict = dictionary;
    if (dict == null || _primed) {
      return;
    }
    _primed = true;
    if (!dict.usableForEncode) {
      return;
    }
    final content = dict.content;
    _buffer.setRange(0, content.length, content);
    _blocks.prime(_buffer, 0, content.length, dict);
    _rep.setAll(0, dict.repeatOffsets);
    _at = content.length;
    _filled = content.length;
  }

  var _primed = false;

  Uint8List _makeBuffer() {
    var slack = _blocks.slideCost;
    if (slack < _matchWindow) {
      slack = _matchWindow;
    }
    return Uint8List((_encodeDictionary?.content.length ?? 0) +
        _matchWindow +
        slack +
        _blockSizeMax +
        _blocks.slideStep);
  }

  @override
  void step() {
    final size = contentSize;
    if (size != null && _content + available > size) {
      throw ArchiveException('Input is longer than contentSize $size');
    }
    if (size == _blockSizeMax) {
      return;
    }
    while (available >= _blockSizeMax) {
      _gather(_blockSizeMax);
      _encodeGathered(last: false);
    }
  }

  @override
  void finish() {
    final size = contentSize;
    if (size != null && _content + available != size) {
      throw ArchiveException(
          'Input is ${_content + available} bytes, contentSize is $size');
    }
    // `ZSTD_CCtx_init_compressStream2` takes the pledged size from the call
    // that ends the frame, so a frame that never carried a byte is the single
    // segment one the reference writes, not a streamed header over nothing
    if (!_started && _content == 0 && available == 0) {
      _writeEmptyHeader();
    } else {
      _writeHeader();
    }
    if (available > 0) {
      _gather(available);
    }
    _encodeGathered(last: true);
    if (checksum) {
      writeZstdMtChecksum(_out, _hash.digestLow);
    }
    _out.flush();
  }

  /// Takes [count] bytes of what arrived into the window, sliding it first if
  /// what is held no longer leaves room
  void _gather(int count) {
    _prime();
    if (_filled + count > _buffer.length) {
      var delta = _at > _matchWindow ? _at - _matchWindow : 0;
      delta -= delta % _blocks.slideStep;
      if (delta > 0) {
        _buffer.setRange(0, _filled - delta, _buffer, delta);
        _at -= delta;
        _filled -= delta;
        _base = _base > delta ? _base - delta : 0;
        _blocks.slide(delta);
      }
    }
    // On a wrap the reference writes over the oldest bytes of the ring, so what
    // it still holds stops being contiguous with what comes now. The window it
    // reaches over is unchanged, only its low part is now a segment of its own
    if (_content > 0 && _content % _ring == 0) {
      _blocks.cut(_filled);
    }
    final piece = view(count);
    _buffer.setRange(_filled, _filled + count, piece);
    if (checksum) {
      _hash.update(_buffer, _filled, count);
    }
    _filled += count;
    _content += count;
    skip(count);
  }

  /// Encodes everything gathered and not yet written. The splitter runs inside
  /// this one gathering, never across two. That is the whole difference
  void _encodeGathered({required bool last}) {
    _writeHeader();
    var left = _filled - _at;
    if (left == 0) {
      if (last) {
        _blocks.encode(_buffer, _at, _at, _base, _out, true, _rep);
      }
      return;
    }
    while (left > 0) {
      final take = _splitter.sizeFor(
          _buffer, _at, left, _blockSizeMax, _params, _savings);
      // `ZSTD_checkDictValidity` measures from the end of the block, and what
      // it drops stays dropped
      if (_blocks.dictionaryEnd != 0 &&
          _at + take - _blocks.dictionaryEnd > _matchWindow) {
        _blocks.dropDictionary();
      }
      final reach = _blocks.dictionaryEnd != 0 ? _base : _at - _matchWindow;
      final before = _out.written;
      _blocks.encode(_buffer, _at, _at + take, reach > _base ? reach : _base,
          _out, last && take == left, _rep);
      _savings += take - (_out.written - before);
      _at += take;
      left -= take;
    }
  }

  /// `ZSTD_writeFrameHeader` for a frame without content size unless
  /// [contentSize] is provided
  void _writeHeader() {
    if (_started) {
      return;
    }
    _started = true;
    final size = contentSize;
    if (size != null) {
      writeZstdFrameHeader(
          _out, size, checksum, _params.windowLog, _encodeDictionary?.id ?? 0);
      return;
    }
    writeZstdMtStreamHeader(_out, checksum, level, _encodeDictionary?.id ?? 0);
  }

  /// The header of a frame whose content is empty: the single segment flag
  /// replaces the window byte, and the size follows it in one byte
  void _writeEmptyHeader() {
    _started = true;
    writeZstdMtStreamHeader(
        _out, checksum, level, _encodeDictionary?.id ?? 0, true);
  }
}

/// Decodes a zstd archive that arrives in pieces.
///
/// The unit of progress is one block, at most 128 KiB, so memory holds the
/// frame's window and one block regardless of archive size
class ZstdChunkedDecoder extends ChunkedSink {
  final bool verify;
  final ZstdDictionary? dictionary;
  final int maxWindowSize;

  ZstdChunkedDecoder(super.output,
      {this.verify = true,
      this.dictionary,
      this.maxWindowSize = zstdDefaultMaxWindowSize}) {
    // ZstdDecoderConverter is const and cannot check the limit. The check
    // happens here. The message matches ZstdDecoder
    if (maxWindowSize < 1024) {
      throw ArgumentError.value(maxWindowSize, 'maxWindowSize',
          'Must be at least the 1 KB minimum window');
    }
  }

  late final _sink = SinkOutputStream(output);
  final _blocks = ZstdBlockDecoder();
  final _rep = Uint32List(3);
  final _hash = Xxh64();
  final _blockHeader = Uint8List(3);

  _Stage _stage = _Stage.magic;
  ZstdFrameHeader? _header;
  ZstdWindow? _window;
  var _frames = 0;
  var _skipped = 0;
  var _checked = false;
  var _produced = 0;
  var _skipLeft = 0;
  var _bodyLength = 0;
  var _blockSizeMax = 0;

  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.magic:
          if (available < 4) {
            // Refused on the first byte no frame starts with, not waited on
            if (available > 0) {
              final head = view(available);
              final skippable = head[0] & 0xf0 == 0x50;
              if (!skippable && head[0] != 0x28) {
                throw ArchiveException('zstd: not a zstd frame');
              }
              const rest = [
                [0xb5, 0x2f, 0xfd],
                [0x2a, 0x4d, 0x18],
              ];
              for (var i = 1; i < head.length; i++) {
                if (head[i] != rest[skippable ? 1 : 0][i - 1]) {
                  throw ArchiveException('zstd: not a zstd frame');
                }
              }
            }
            return;
          }
          _readMagic();
        case _Stage.skippableSize:
          if (available < 4) {
            return;
          }
          _skipLeft = _uint32(view(4));
          skip(4);
          _stage = _Stage.skippableBody;
        case _Stage.skippableBody:
          // A skippable frame may declare no body at all, and waiting on a
          // byte for it leaves the stage unfinished at the end of the input
          if (_skipLeft > 0) {
            if (available == 0) {
              return;
            }
            final take = available < _skipLeft ? available : _skipLeft;
            skip(take);
            _skipLeft -= take;
            if (_skipLeft > 0) {
              return;
            }
          }
          _stage = _Stage.magic;
        case _Stage.frameHeader:
          if (available < 1) {
            return;
          }
          final size = _headerSize(view(1)[0]);
          if (available < size) {
            return;
          }
          _readFrameHeader(size);
        case _Stage.blockHeader:
          if (available < 3) {
            return;
          }
          _readBlockHeader();
        case _Stage.blockBody:
          if (available < _bodyLength) {
            return;
          }
          _readBlockBody();
          if (unitAtATime) {
            return;
          }
        case _Stage.checksum:
          if (available < 4) {
            return;
          }
          _readChecksum();
      }
    }
  }

  @override
  void finish() {
    if (_stage != _Stage.magic || available != 0) {
      throw ArchiveException('zstd: unexpected end of archive');
    }
    // An input of only skippable frames decodes to nothing rather than
    // failing, as the reference does
    if (_frames == 0 && _skipped == 0) {
      throw ArchiveException('zstd: no frame, the input is empty');
    }
    _sink.flush();
  }

  static int _uint32(Uint8List bytes) =>
      bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);

  void _readMagic() {
    final magic = _uint32(view(4));
    skip(4);
    if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
      _stage = _Stage.skippableSize;
      _skipped++;
      return;
    }
    if (magic != zstdMagic) {
      throw ArchiveException('zstd: not a zstd frame');
    }
    _stage = _Stage.frameHeader;
  }

  /// Size of the rest of the header, from the descriptor: the window byte
  /// unless the frame is one segment, the dictionary id, and the content size
  static int _headerSize(int descriptor) {
    const fcsSizes = [0, 2, 4, 8];
    const dictSizes = [0, 1, 2, 4];
    final fcsFlag = descriptor >> 6;
    final singleSegment = (descriptor >> 5) & 1 != 0;
    final fcs = fcsFlag == 0 ? (singleSegment ? 1 : 0) : fcsSizes[fcsFlag];
    return 1 + (singleSegment ? 0 : 1) + dictSizes[descriptor & 3] + fcs;
  }

  void _readFrameHeader(int size) {
    final header = readFrameHeader(view(size), 0, size, maxWindowSize);
    final dictionary = this.dictionary;
    if (header.dictionaryId != 0 &&
        (dictionary == null || dictionary.id != header.dictionaryId)) {
      throw ArchiveException(
          'zstd: frame needs dictionary ${header.dictionaryId}');
    }
    skip(size);

    final window = ZstdWindow(header.windowSize, output: _sink)
      ..blockReserve = header.blockReserve;
    if (dictionary != null && dictionary.content.isNotEmpty) {
      window.prime(dictionary.content);
    }
    _window = window;
    _header = header;
    _blockSizeMax = header.blockSizeMax;
    _blocks.reset(dictionary);
    _rep.setAll(0, dictionary?.repeatOffsets ?? zstdInitialRepeatOffsets);
    _checked = header.hasChecksum && verify;
    if (_checked) {
      _hash.reset();
    }
    _produced = 0;
    _stage = _Stage.blockHeader;
  }

  void _readBlockHeader() {
    final field = view(3);
    _blockHeader
      ..[0] = field[0]
      ..[1] = field[1]
      ..[2] = field[2];
    final header = field[0] | (field[1] << 8) | (field[2] << 16);
    final type = (header >> 1) & 3;
    final size = header >> 3;
    if (type == zstdBlockReserved) {
      throw ArchiveException('zstd: a block names the reserved type');
    }
    if (size > _blockSizeMax) {
      throw ArchiveException(
          'zstd: block of $size bytes is above the $_blockSizeMax its frame '
          'allows');
    }
    _bodyLength = type == zstdBlockRle ? 1 : size;
    skip(3);
    _stage = _Stage.blockBody;
  }

  void _readBlockBody() {
    final window = _window!;
    window.reserve(_header!.blockReserve);
    final from = window.position;
    _blocks.decode(_blockHeader, 0, 3, window, _rep, _blockSizeMax,
        body: view(_bodyLength), bodyAt: 0);
    if (_checked) {
      _hash.update(window.buffer, from, window.position - from);
    }
    _produced += window.position - from;
    final declared = _header!.contentSize;
    if (declared != null && _produced > declared) {
      throw ArchiveException('zstd: frame produced $_produced bytes against '
          'the $declared it declared');
    }
    // Out at the end of every block, as ZSTD_decompressStream does. The input
    // may pause without closing
    window.emit();
    _sink.flush();
    skip(_bodyLength);
    if (!_blocks.isLast) {
      _stage = _Stage.blockHeader;
      return;
    }
    final expected = _header!.contentSize;
    if (expected != null && _produced != expected) {
      throw ArchiveException('zstd: frame produced $_produced bytes against '
          'the $expected it declared');
    }
    if (_header!.hasChecksum) {
      _stage = _Stage.checksum;
      return;
    }
    _endFrame();
  }

  void _readChecksum() {
    final stored = _uint32(view(4));
    skip(4);
    if (_checked && _hash.digestLow != stored) {
      throw ArchiveChecksumException('zstd: content checksum does not match');
    }
    _endFrame();
  }

  void _endFrame() {
    _window!.finish();
    // Out now, not held in the sink: the input may pause without closing
    _sink.flush();
    _window = null;
    _header = null;
    _frames++;
    _stage = _Stage.magic;
  }
}

enum _Stage {
  magic,
  skippableSize,
  skippableBody,
  frameHeader,
  blockHeader,
  blockBody,
  checksum,
}

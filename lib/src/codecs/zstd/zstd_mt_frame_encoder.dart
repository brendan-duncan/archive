import 'dart:typed_data';

import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../../util/report_progress.dart';
import '../../util/xxh64.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_ldm.dart';
import 'zstd_level_params.dart';
import 'zstd_mt_parallel.dart';

/// `4*ZSTD_BLOCKSIZE_MAX`, the piece a job's input reaches the compressor in.
/// Every piece ends a block, so a threaded frame differs from a single
/// threaded one
const zstdMtChunkSize = 4 * zstdBlockMaximumSize;

/// `ZSTDMT_JOBSIZE_MIN`: at or below this the reference drops its workers, so
/// the frame is the one the single threaded encoder writes
const zstdMtJobSizeMin = 512 * 1024;

/// `ZSTDMT_JOBSIZE_MAX` on a 64 bit build
const zstdMtJobSizeMax = 1024 * 1024 * 1024;

/// Whether the long distance matcher is on, which changes how a threaded frame
/// is cut as well as where its matches come from
bool zstdMtLongRange(ZstdLevelParams params) =>
    ZstdLdm.forParams(params.refStrategy, params.windowLog) != null;

/// `ZSTDMT_JOBLOG_MAX`
const _jobLogMax = 29;

/// What the reference reads for a size it has not been told. It picks the level
/// row from this and leaves the window unclamped
const zstdMtSizeUnknown = 1099511627776;

/// Writes the frame `ZSTD_compress2` writes with `nbWorkers` above zero: the
/// input cut into jobs, each parsed from its own tables over a prefix of the
/// one before, and every job fed to the block loop a chunk at a time.
///
/// This is the single threaded form of that. It exists to be compared against
/// the reference before any isolate does the work, and it shares no state with
/// [ZstdFrameEncoder], whose bytes must not move
class ZstdMtFrameEncoder {
  final Xxh64 _hash = Xxh64();
  final Uint32List _rep = Uint32List(3);
  final ZstdBlockSplitter _splitter = ZstdBlockSplitter();

  /// [jobSize] and [overlapLog] are `ZSTD_c_jobSize` and `ZSTD_c_overlapLog`,
  /// zero for the level's own
  void encode(Uint8List src, int start, int end, OutputStream out,
      {bool checksum = true,
      int level = zstdDefaultLevel,
      int jobSize = 0,
      int overlapLog = 0}) {
    final size = end - start;
    final params = zstdParamsForLevel(level, size);
    final matchWindow = 1 << params.windowLog;
    final singleSegment = size <= matchWindow;
    final windowSize = singleSegment ? size : matchWindow;

    _writeHeader(out, size, singleSegment, checksum, params.windowLog);
    if (checksum) {
      _hash.reset();
      _hash.update(src, start, size);
    }

    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    final prefixSize = _prefixSize(params, overlapLog);
    var job = _jobSize(jobSize, params);
    if (job < prefixSize) {
      job = prefixSize;
    }

    final pass = ZstdMtLdmPass.forParams(params, job);
    var at = start;
    var first = true;
    while (first || at < end) {
      first = false;
      final jobEnd = end - at < job ? end : at + job;
      final lastJob = jobEnd >= end;
      final before = at - start;
      final prefix = before < prefixSize ? before : prefixSize;
      _encodeJob(
          src,
          at - prefix,
          at,
          jobEnd,
          out,
          matchWindow,
          blockSizeMax,
          params,
          at == start,
          lastJob && jobEnd == end,
          null,
          pass?.generate(src, at, jobEnd));
      at = jobEnd;
      if (lastJob) {
        break;
      }
    }

    if (checksum) {
      _writeChecksum(out, _hash.digestLow);
    }
  }

  /// One job, its input passed to the block loop in [zstdMtChunkSize] pieces.
  /// The splitter sees a piece as the whole of what is left. That cuts a block
  /// short at every piece boundary
  void _encodeJob(
      Uint8List src,
      int base,
      int start,
      int end,
      OutputStream out,
      int matchWindow,
      int blockSizeMax,
      ZstdLevelParams params,
      bool firstJob,
      bool lastJob,
      ZstdDictionary? dictionary,
      ZstdLdmSequences? ldmSequences,
      {void Function(int done)? onBlock}) {
    // `ZSTDMT_compressionJob` turns the matcher off inside a job, found or not
    final blocks = zstdMtLongRange(params)
        ? ZstdBlockEncoder.external(blockSizeMax, params, ldmSequences)
        : ZstdBlockEncoder(blockSizeMax, params);
    if (dictionary != null) {
      // Only the first job is given one, as `ZSTDMT_compressionJob` asserts,
      // and it takes its repeat offsets from it rather than from the frame's
      blocks.prime(src, base, start, dictionary);
      _rep.setAll(0, dictionary.repeatOffsets);
    } else {
      if (start > base) {
        // `forceMaxWindow` leaves `loadedDictEnd` at zero, so the prefix is
        // bounded by the window like any other input
        blocks.primeRawPrefix(src, base, start);
      }
      // `ZSTD_invalidateRepCodes`: a job after the first starts with no usable
      // repeat offsets at all, not with the frame's initial three
      _rep.setAll(0, firstJob ? zstdInitialRepeatOffsets : const [0, 0, 0]);
    }
    var savings = 0;
    var at = start;
    if (start == end) {
      blocks.encode(src, at, at, at, out, lastJob, _rep);
      return;
    }
    while (at < end) {
      final done = at - start;
      var chunkEnd = start + (done - done % zstdMtChunkSize) + zstdMtChunkSize;
      if (chunkEnd > end) {
        chunkEnd = end;
      }
      final take = _splitter.sizeFor(
          src, at, chunkEnd - at, blockSizeMax, params, savings);
      // `ZSTD_checkDictValidity` measures from the end of the block, and what
      // it drops stays dropped
      if (blocks.dictionaryEnd != 0 &&
          at + take - blocks.dictionaryEnd > matchWindow) {
        blocks.dropDictionary();
      }
      final reach = blocks.dictionaryEnd != 0 ? base : at - matchWindow;
      final before = out.length;
      blocks.encode(src, at, at + take, reach > base ? reach : base, out,
          lastJob && at + take == end, _rep);
      savings += take - (out.length - before);
      at += take;
      onBlock?.call(at - start);
      // The first block's cost predicts the rest, near enough to take the
      // room once instead of doubling into it. A job never exceeds its own
      // bound, so neither does the estimate
      if (at - start == take && at < end) {
        final span = end - start;
        final bound = span + (span >> 7) + 64;
        var want = out.length + (out.length * (end - at)) ~/ take;
        want += want >> 3;
        out.reserve(want < bound ? want : bound);
      }
    }
  }

  /// `ZSTDMT_computeTargetJobLog` without the long distance matcher, which
  /// this path does not take yet
  static int _targetJobLog(ZstdLevelParams params) {
    final int log;
    if (zstdMtLongRange(params)) {
      // `ZSTDMT_computeTargetJobLog`: sized from the cycle, the window is wide
      final cycleLog = params.chainLog - (params.refStrategy >= 6 ? 1 : 0);
      log = cycleLog + 3 > 21 ? cycleLog + 3 : 21;
    } else {
      log = params.windowLog + 2 > 20 ? params.windowLog + 2 : 20;
    }
    return log > _jobLogMax ? _jobLogMax : log;
  }

  /// `ZSTDMT_computeOverlapSize`
  static int _prefixSize(ZstdLevelParams params, int overlapLog) {
    final log = overlapLog > 0 ? overlapLog : _overlapLogDefault(params);
    final reverse = 9 - log;
    if (zstdMtLongRange(params)) {
      // `ZSTDMT_computeOverlapSize`: a fraction of the job, not of the window
      final jobLog = _targetJobLog(params);
      final ceiling =
          params.windowLog < jobLog - 2 ? params.windowLog : jobLog - 2;
      final ovLog = ceiling - reverse;
      return ovLog <= 0 ? 0 : 1 << ovLog;
    }
    if (reverse >= 8) {
      return 0;
    }
    return 1 << (params.windowLog - reverse);
  }

  /// `ZSTD_CCtxParams_setParameter` raises a given size to `ZSTDMT_JOBSIZE_MIN`
  /// and then clamps it to the bounds, whose upper end is `ZSTDMT_JOBSIZE_MAX`
  static int _jobSize(int given, ZstdLevelParams params) {
    if (given <= 0) {
      return 1 << _targetJobLog(params);
    }
    if (given < zstdMtJobSizeMin) {
      return zstdMtJobSizeMin;
    }
    return given > zstdMtJobSizeMax ? zstdMtJobSizeMax : given;
  }

  /// `ZSTDMT_overlapLog_default`, by the reference's own strategy numbering,
  /// which [ZstdLevelParams.refStrategy] holds
  static int _overlapLogDefault(ZstdLevelParams params) {
    switch (params.refStrategy) {
      case 9:
        return 9;
      case 8:
      case 7:
        return 8;
      case 6:
      case 5:
        return 7;
      default:
        return 6;
    }
  }

  static void _writeHeader(OutputStream out, int size, bool singleSegment,
      bool checksum, int windowLog,
      [int dictionaryId = 0]) {
    final int contentSizeFlag;
    if (singleSegment && size < 256) {
      contentSizeFlag = 0;
    } else if (size >= 256 && size < 65536 + 256) {
      contentSizeFlag = 1;
    } else if (size < 4294967295) {
      contentSizeFlag = 2;
    } else {
      contentSizeFlag = 3;
    }

    out.writeByte(zstdMagic & 0xff);
    out.writeByte((zstdMagic >>> 8) & 0xff);
    out.writeByte((zstdMagic >>> 16) & 0xff);
    out.writeByte((zstdMagic >>> 24) & 0xff);
    // `ZSTD_writeFrameHeader`: as many bytes as the id needs, and the flag
    // names which of the four widths that is
    final idFlag = dictionaryId == 0
        ? 0
        : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));
    out.writeByte((contentSizeFlag << 6) |
        (singleSegment ? 0x20 : 0) |
        (checksum ? 4 : 0) |
        idFlag);
    if (!singleSegment) {
      out.writeByte((windowLog - 10) << 3);
    }
    final idBytes = const [0, 1, 2, 4][idFlag];
    for (var i = 0; i < idBytes; i++) {
      out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
    }

    if (contentSizeFlag == 0) {
      out.writeByte(size);
    } else if (contentSizeFlag == 1) {
      final value = size - 256;
      out.writeByte(value & 0xff);
      out.writeByte((value >>> 8) & 0xff);
    } else if (contentSizeFlag == 2) {
      for (var i = 0; i < 4; i++) {
        out.writeByte((size >>> (i << 3)) & 0xff);
      }
    } else {
      for (var i = 0; i < 8; i++) {
        out.writeByte((size >>> (i << 3)) & 0xff);
      }
    }
  }

  /// The span of one job and the prefix before it. A caller cuts the input up
  /// by these before sending the pieces out
  static List<int> geometry(int level, int size,
      {int jobSize = 0, int overlapLog = 0}) {
    final params = zstdParamsForLevel(level, size);
    final prefix = _prefixSize(params, overlapLog);
    var job = _jobSize(jobSize, params);
    if (job < prefix) {
      job = prefix;
    }
    return [job, prefix];
  }

  /// A single job that holds nothing between calls: [buffer] is its prefix
  /// followed by its own span, and [size] the whole frame's
  static void encodeJob(
      Uint8List buffer, int prefix, OutputStream out, int level, int size,
      {required bool firstJob,
      required bool lastJob,
      int jobSize = 0,
      int overlapLog = 0,
      ZstdDictionary? dictionary,
      ZstdLdmSequences? ldmSequences,
      void Function(int done)? onBlock}) {
    final params = zstdParamsForLevel(level, size);
    final matchWindow = 1 << params.windowLog;
    final windowSize = size <= matchWindow ? size : matchWindow;
    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    ZstdMtFrameEncoder()._encodeJob(
        buffer,
        0,
        prefix,
        buffer.length,
        out,
        matchWindow,
        blockSizeMax,
        params,
        firstJob,
        lastJob,
        dictionary,
        ldmSequences,
        onBlock: onBlock);
  }
}

/// One job's matches as they cross a port, trimmed to what was found
List<Object>? zstdMtPackLdm(ZstdLdmSequences? found) => found == null
    ? null
    : [
        Uint32List.sublistView(found.litLength, 0, found.size),
        Uint32List.sublistView(found.matchLength, 0, found.size),
        Uint32List.sublistView(found.offset, 0, found.size),
      ];

/// The other side of [zstdMtPackLdm]
ZstdLdmSequences? zstdMtUnpackLdm(Object? packed) {
  if (packed == null) {
    return null;
  }
  final parts = packed as List;
  final litLength = parts[0] as Uint32List;
  final out = ZstdLdmSequences(litLength.length + 1);
  out.litLength.setRange(0, litLength.length, litLength);
  out.matchLength.setRange(0, litLength.length, parts[1] as Uint32List);
  out.offset.setRange(0, litLength.length, parts[2] as Uint32List);
  out.size = litLength.length;
  return out;
}

/// `ZSTDMT_serialState_genSequences`, since a job sees only its own prefix
class ZstdMtLdmPass {
  final ZstdLdm _ldm;

  /// The frame's window. The reference's round buffer holds the same
  final int _windowSize;
  final int _capacity;
  Uint8List _held = Uint8List(0);
  var _filled = 0;

  ZstdMtLdmPass._(this._ldm, this._windowSize, this._capacity);

  /// Null where this level's parameters leave the matcher off
  static ZstdMtLdmPass? forParams(ZstdLevelParams params, int jobSize) {
    final ldm = ZstdLdm.forParams(params.refStrategy, params.windowLog);
    if (ldm == null) {
      return null;
    }
    return ZstdMtLdmPass._(ldm, 1 << params.windowLog, jobSize);
  }

  /// The matches covering `[start, end)`, which must follow what came before
  ZstdLdmSequences generate(Uint8List src, int start, int end) {
    _append(src, start, end);
    // `ZSTD_ldm_getMaxNbSeq` sizes the pool from the job size
    var capacity = _capacity ~/ _ldm.minMatch;
    final possible = (end - start) ~/ _ldm.minMatch + 1;
    if (capacity > possible) {
      capacity = possible;
    }
    if (capacity < 1) {
      capacity = 1;
    }
    final out = ZstdLdmSequences(capacity);
    final to = _filled;
    final from = to - (end - start);
    _ldm.generate(_held, ByteData.sublistView(_held), from, to, out);
    return out;
  }

  void _append(Uint8List src, int start, int end) {
    final size = end - start;
    final want = _windowSize + _capacity;
    if (_filled + size > _held.length) {
      final grown = _filled + size < want ? _filled + size : want;
      if (grown > _held.length) {
        final next = Uint8List(grown);
        next.setRange(0, _filled, _held);
        _held = next;
      }
    }
    if (_filled + size > _held.length) {
      // Nothing older than the window matches, so it goes
      final drop = _filled + size - _held.length;
      _held.setRange(0, _filled - drop, _held, drop);
      _filled -= drop;
      _ldm.slide(drop);
    }
    _held.setRange(_filled, _filled + size, src, start);
    _filled += size;
  }
}

/// Cuts a stream of arriving bytes into jobs. Each job has the prefix the
/// reference gives it, the tail of the job before, so a worker needs nothing
/// else; the ring holds one job and one prefix at a time
class ZstdMtRing {
  final int jobSize;
  final int prefixSize;

  /// Copying: what arrives may be filled again the moment the call returns
  final _held = BytesBuilder(copy: true);
  Uint8List _prefix = Uint8List(0);
  var _jobs = 0;

  ZstdMtRing(this.jobSize, this.prefixSize);

  int get jobCount => _jobs;

  /// Takes what arrived and returns the jobs it completes, prefix included
  List<Uint8List> add(List<int> data) {
    _held.add(data);
    final out = <Uint8List>[];
    while (_held.length >= jobSize) {
      final taken = _held.takeBytes();
      out.add(_cut(Uint8List.sublistView(taken, 0, jobSize)));
      _held.add(Uint8List.sublistView(taken, jobSize));
    }
    return out;
  }

  /// The last job, whatever is left. It may be empty
  Uint8List close() => _cut(_held.takeBytes());

  Uint8List _cut(Uint8List body) {
    final job = Uint8List(_prefix.length + body.length)
      ..setRange(0, _prefix.length, _prefix)
      ..setRange(_prefix.length, _prefix.length + body.length, body);
    final keep = body.length < prefixSize ? body.length : prefixSize;
    // A view would keep the whole job alive behind it, so the tail is copied
    _prefix = Uint8List.fromList(Uint8List.sublistView(job, job.length - keep));
    _jobs++;
    return job;
  }
}

/// What one worker holds: the copy of its job and prefix that crossed the
/// port, the output it builds, and the level's tables
int zstdMtWorkerCost(int level, int size, List<int> geometry) {
  final params = zstdParamsForLevel(level, size);
  final span = geometry[0] < size ? geometry[0] : size;
  final tables = (1 << params.hashLog) * 4 +
      (1 << params.chainLog) * 4 +
      (1 << params.windowLog);
  return span + geometry[1] + span + (span >> 7) + 64 + tables;
}

/// The threaded frame of a file, written into [out] without the input ever
/// sitting in this isolate: a worker reads its own job from disk
Future<void> zstdMtCompressFile(
    String path, int offset, int size, int level, OutputStream out,
    {bool checksum = true,
    int jobSize = 0,
    int overlapLog = 0,
    int workers = 1,
    int memoryBudget = 0,
    void Function(int consumed)? onProgress}) async {
  final geometry = ZstdMtFrameEncoder.geometry(level, size,
      jobSize: jobSize, overlapLog: overlapLog);
  final starts = _jobStarts(size, geometry[0]);
  final params = zstdParamsForLevel(level, size);
  ZstdMtFrameEncoder._writeHeader(
      out, size, size <= 1 << params.windowLog, checksum, params.windowLog);
  await zstdMtCompressFileJobs(path, offset, size, starts, geometry[1], level,
      jobSize: jobSize,
      overlapLog: overlapLog,
      workers: workers,
      cap: zstdMtWorkerCap(memoryBudget, level, size, geometry),
      onPart: out.writeBytes,
      onProgress: onProgress);
  if (checksum) {
    _writeChecksum(out, zstdMtFileDigest(path, offset, size));
  }
}

List<int> _jobStarts(int size, int job) {
  final starts = <int>[0];
  for (var at = job; at < size; at += job) {
    starts.add(at);
  }
  return starts;
}

/// The pool a run gets: what was asked for up to one worker a core, or one
/// worker a core with one left for this isolate, lowered to what the budget
/// affords and never below one
int zstdMtPoolSize(int workers, int cores, int cap) {
  var pool = workers > 0 ? workers : cores - 1;
  if (pool > cores) {
    pool = cores;
  }
  if (cap > 0 && pool > cap) {
    pool = cap;
  }
  return pool < 1 ? 1 : pool;
}

/// How many workers a budget allows, zero for no bound and never below one
int zstdMtWorkerCap(int memoryBudget, int level, int size, List<int> geometry) {
  if (memoryBudget <= 0) {
    return 0;
  }
  final cap = memoryBudget ~/ zstdMtWorkerCost(level, size, geometry);
  return cap < 1 ? 1 : cap;
}

/// The header a streamed frame opens with: no content size, because it is not
/// known when the header is written, and the level's window unclamped. With
/// [empty] it is nothing, the one case `ZSTD_CCtx_init_compressStream2` knows
/// the size in: the call that ends the frame is also the first
void writeZstdMtStreamHeader(OutputStream out, bool checksum, int level,
    [int dictionaryId = 0, bool empty = false]) {
  final params = zstdParamsForLevel(level, zstdMtSizeUnknown);
  final idFlag = dictionaryId == 0
      ? 0
      : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));
  out.writeByte(zstdMagic & 0xff);
  out.writeByte((zstdMagic >>> 8) & 0xff);
  out.writeByte((zstdMagic >>> 16) & 0xff);
  out.writeByte((zstdMagic >>> 24) & 0xff);
  out.writeByte((empty ? 0x20 : 0) | (checksum ? 4 : 0) | idFlag);
  if (!empty) {
    out.writeByte((params.windowLog - 10) << 3);
  }
  for (var i = 0; i < const [0, 1, 2, 4][idFlag]; i++) {
    out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
  }
  if (empty) {
    out.writeByte(0);
  }
}

/// The four checksum bytes a frame ends with, taken over the whole input
void writeZstdMtChecksum(OutputStream out, int digest) =>
    _writeChecksum(out, digest);

void _writeChecksum(OutputStream out, int digest) {
  out.writeByte(digest & 0xff);
  out.writeByte((digest >>> 8) & 0xff);
  out.writeByte((digest >>> 16) & 0xff);
  out.writeByte((digest >>> 24) & 0xff);
}

/// The threaded frame, its jobs compressed wherever [zstdMtCompressJobs] puts
/// them and pasted together in job order. The header and the checksum are not
/// included, since a job writes neither
Future<Uint8List> zstdMtCompress(Uint8List src, int level,
    {bool checksum = true,
    int jobSize = 0,
    int overlapLog = 0,
    int workers = 1,
    int memoryBudget = 0,
    ZstdDictionary? dictionary,
    void Function(int consumed)? onProgress}) async {
  // `ZSTD_getCParamsFromCCtxParams` sizes the frame by the content and the
  // dictionary buffer together, as the single threaded frame does
  final sized = src.length + (dictionary?.sourceSize ?? 0);
  final geometry = ZstdMtFrameEncoder.geometry(level, sized,
      jobSize: jobSize, overlapLog: overlapLog);
  final starts = <int>[0];
  for (var at = geometry[0]; at < src.length; at += geometry[0]) {
    starts.add(at);
  }
  final cap = zstdMtWorkerCap(memoryBudget, level, sized, geometry);
  // The reference gives the dictionary to job zero only, so that one is done
  // here rather than plumbed through the port, and the rest go to the pool
  Uint8List? firstPart;
  var rest = starts;
  ZstdMtLdmPass? ldmPass;
  if (dictionary != null) {
    // `ZSTDMT_serialState_genSequences` runs one long distance pass over every
    // job in order. Job zero is in it, so the pass starts here
    ldmPass =
        ZstdMtLdmPass.forParams(zstdParamsForLevel(level, sized), geometry[0]);
    final firstEnd = starts.length > 1 ? starts[1] : src.length;
    final content = dictionary.content;
    final held = Uint8List(content.length + firstEnd)
      ..setRange(0, content.length, content)
      ..setRange(content.length, content.length + firstEnd, src);
    final out0 = OutputMemoryStream();
    ZstdMtFrameEncoder.encodeJob(held, content.length, out0, level, sized,
        firstJob: true,
        lastJob: starts.length == 1,
        jobSize: jobSize,
        overlapLog: overlapLog,
        dictionary: dictionary,
        ldmSequences: ldmPass?.generate(src, 0, firstEnd),
        onBlock: (done) => reportProgress(onProgress, done));
    firstPart = out0.getBytes();
    rest = starts.sublist(1);
    reportProgress(onProgress, firstEnd);
  }
  final parts = rest.isEmpty
      ? const <Uint8List>[]
      : await zstdMtCompressJobs(src, rest, geometry[1], level,
          jobSize: jobSize,
          overlapLog: overlapLog,
          workers: workers,
          cap: cap,
          firstIsFirstJob: dictionary == null,
          size: src.length,
          paramsSize: sized,
          ldmPass: ldmPass,
          onProgress: onProgress);

  final out = OutputMemoryStream();
  final params = zstdParamsForLevel(level, sized);
  ZstdMtFrameEncoder._writeHeader(
      out,
      src.length,
      src.length <= 1 << params.windowLog,
      checksum,
      params.windowLog,
      dictionary?.id ?? 0);
  if (firstPart != null) {
    out.writeBytes(firstPart);
  }
  for (final part in parts) {
    out.writeBytes(part);
  }
  if (checksum) {
    final hash = Xxh64()..reset();
    hash.update(src, 0, src.length);
    _writeChecksum(out, hash.digestLow);
  }
  return out.getBytes();
}

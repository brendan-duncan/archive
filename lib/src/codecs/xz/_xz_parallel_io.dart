import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// The io file handle is imported directly rather than through
// file_handle.dart, whose conditional export resolves to the web class when
// the analyser has no platform in mind, and that one has no path.
import '../../util/_file_handle_io.dart';
import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/decode_guard.dart';
import '../../util/input_file_stream.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import 'xz_block_dispatch.dart';
import 'xz_chunked.dart';
import 'xz_index.dart';
import 'xz_multithread_options.dart';
import 'xz_stream_decoder.dart';

/// Whether this platform can decode on isolates.
const bool xzIsolatesSupported = true;

/// A stretch of a file on disk holding an xz archive.
class XZFileRegion {
  final String path;
  final int offset;
  final int length;

  const XZFileRegion(this.path, this.offset, this.length);
}

/// Enables isolates to read directly from disk, bypassing the calling isolate
/// entirely. Streams without a physical file fall back to the standard memory
/// path
XZFileRegion? xzFileRegionOf(InputStream input) {
  if (input is! InputFileStream) {
    return null;
  }
  final handle = input.fileBuffer.file;
  if (handle is! FileHandle) {
    return null;
  }
  return XZFileRegion(
      handle.path, input.fileOffset + input.position, input.length);
}

/// Reads the block layout of the archive in [region] without loading it.
XZLayout? xzLayoutOfFile(XZFileRegion region, {int? maxUncompressedSize}) {
  final file = File(region.path).openSync();
  try {
    return parseXZLayout(_XZFileSource(file, region.offset, region.length),
        maxUncompressedSize: maxUncompressedSize);
  } catch (_) {
    return null;
  } finally {
    file.closeSync();
  }
}

/// A file-backed [XZByteSource] optimized for lazy extraction, keeping I/O
/// under a few kilobytes by parsing only the structural metadata (header,
/// index, and footer)
class _XZFileSource extends XZByteSource {
  final RandomAccessFile _file;
  final int _offset;

  @override
  final int length;

  _XZFileSource(this._file, this._offset, this.length);

  @override
  Uint8List range(int start, int end) {
    _file.setPositionSync(_offset + start);
    return _file.readSync(end - start);
  }
}

// The largest block header the format allows, (255 + 1) * 4.
const _maxBlockHeaderSize = 1024;

// Caps how many blocks we scan to determine the LZMA2 dictionary size,
// avoiding expensive full-archive reads since the size is practically uniform
// across blocks
const _dictionarySampleLimit = 16;

const _kindStream = 0;
const xzKindBlock = 1;

const _msgReady = 0;
const _msgChunk = 1;
const _msgDone = 2;

/// Using a file [path] is significantly cheaper than raw [bytes] because
/// workers read directly from disk, dodging IPC overhead entirely. Since
/// workers run in isolates, chunks arrive mixed and must be validated against
/// [onBlockDone]. A corrupt block can still push bytes before failing its
/// checksum
Future<bool> xzDecodeMultithreaded({
  Uint8List? bytes,
  String? path,
  int fileOffset = 0,
  int fileLength = 0,
  required XZLayout? layout,
  required bool verify,
  required int maxPreallocateSize,
  int maxDictionarySize = xzDefaultMaxDictionarySize,
  int? workers,
  int? memoryBudget,
  required void Function(int outputOffset, Uint8List chunk) onChunk,
  void Function(int block, bool ok)? onBlockDone,
  void Function(String reason)? onFailureReason,
  bool orderedOutput = false,
  required int fileReadBufferSize,
}) {
  // Offsets in the layout are relative to the start of the archive, which sits
  // at [fileOffset] in a file and at zero in a buffer.
  final base = bytes != null ? 0 : fileOffset;
  final blocks = layout?.blocks;

  if (blocks != null && blocks.length > 1) {
    final dictionaryCap = _largestDictionaryCap(blocks, bytes, path, base);
    final count = _pickWorkerCount(
      blocks: blocks,
      requested: workers,
      memoryBudget: memoryBudget,
      dictionaryCap: dictionaryCap,
      holdsCompressedBlock: bytes != null,
      orderedOutput: orderedOutput,
      fileReadBufferSize: fileReadBufferSize,
    );
    if (count > 1) {
      return _runJobs([
        for (final block in blocks)
          _Job(
            kind: xzKindBlock,
            bytes: bytes,
            path: path,
            offset: base + block.compressedOffset,
            length: block.compressedLength,
            streamFlags: block.streamFlags,
            outputOffset: block.outputOffset,
            verify: verify,
            maxPreallocateSize: maxPreallocateSize,
            maxDictionarySize: maxDictionarySize,
            fileReadBufferSize: fileReadBufferSize,
            uncompressedLength: block.uncompressedLength,
            unpaddedLength: block.unpaddedLength,
          )
      ],
          count,
          onChunk,
          onBlockDone,
          onFailureReason,
          memoryBudget ?? xzDefaultMemoryBudget,
          orderedOutput ? 2 * count : null);
    }
  }

  // Falls back to a single background isolate if the archive is tiny or the
  // worker limit is 1, ensuring the main thread still stays unblocked.
  // A single job processes the entire archive in order, so a block is reported
  // done once output reaches its end
  var done = 0;
  final inOrder = blocks == null || onBlockDone == null
      ? onChunk
      : (int offset, Uint8List chunk) {
          while (done < blocks.length &&
              blocks[done].outputOffset + blocks[done].uncompressedLength <=
                  offset) {
            onBlockDone(done++, true);
          }
          onChunk(offset, chunk);
        };
  return _runJobs([
    _Job(
      kind: _kindStream,
      bytes: bytes,
      path: path,
      offset: base,
      length: bytes?.length ?? fileLength,
      streamFlags: 0,
      outputOffset: 0,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      maxDictionarySize: maxDictionarySize,
      fileReadBufferSize: fileReadBufferSize,
    )
  ], 1, inOrder, null, onFailureReason);
}

/// The memory an LZMA2 dictionary will take for the largest sampled block.
///
/// This mirrors the cap [XZStreamDecoder.readBlock] sets, so that the budget
/// is measured against what a worker actually allocates rather than a guess.
int _largestDictionaryCap(
    List<XZBlockLayout> blocks, Uint8List? bytes, String? path, int base) {
  var largest = 0;
  RandomAccessFile? file;
  try {
    if (bytes == null) {
      file = File(path!).openSync();
    }
    final count = blocks.length < _dictionarySampleLimit
        ? blocks.length
        : _dictionarySampleLimit;
    for (var i = 0; i < count; i++) {
      final block = blocks[i];
      var length = block.compressedLength;
      if (length > _maxBlockHeaderSize) {
        length = _maxBlockHeaderSize;
      }
      Uint8List header;
      if (bytes != null) {
        final start = base + block.compressedOffset;
        if (start + length > bytes.length) {
          continue;
        }
        header = Uint8List.sublistView(bytes, start, start + length);
      } else {
        file!.setPositionSync(base + block.compressedOffset);
        header = file.readSync(length);
      }
      final size = xzBlockDictionarySize(header);
      if (size > largest) {
        largest = size;
      }
    }
  } catch (_) {
    // This only sizes the worker count, so a header that cannot be read falls
    // back to whatever the other blocks reported.
  } finally {
    file?.closeSync();
  }

  if (largest <= 0 || largest >= 0x40000000) {
    return 0;
  }
  return xzDictionaryCap(largest);
}

int _pickWorkerCount({
  required List<XZBlockLayout> blocks,
  required int? requested,
  required int? memoryBudget,
  required int dictionaryCap,
  required bool holdsCompressedBlock,
  required bool orderedOutput,
  required int fileReadBufferSize,
}) {
  final cores = Platform.numberOfProcessors;
  // One core is left to the caller; in Flutter that is the UI isolate.
  var count = requested ?? cores - 1;
  if (count > cores) {
    count = cores;
  }
  if (count < 1) {
    count = 1;
  }
  if (count > blocks.length) {
    count = blocks.length;
  }

  // Workers hold a dictionary, staging buffer, and full compressed block in
  // RAM, while file sources stream via a small window. This global budget also
  // limits worker count
  var compressed = fileReadBufferSize;
  if (holdsCompressedBlock) {
    compressed = 0;
    for (final block in blocks) {
      if (block.compressedLength > compressed) {
        compressed = block.compressedLength;
      }
    }
  }

  // An output that can only be appended to has to hold back blocks that
  // finished ahead of their turn, so every worker beyond the first can leave a
  // whole decoded block waiting in the calling isolate. That is charged to the
  // worker that causes it.
  var reorder = 0;
  if (orderedOutput) {
    for (final block in blocks) {
      if (block.uncompressedLength > reorder) {
        reorder = block.uncompressedLength;
      }
    }
  }

  final perWorker = compressed + dictionaryCap + xzStagingSize + reorder;
  if (perWorker > 0) {
    var affordable = (memoryBudget ?? xzDefaultMemoryBudget) ~/ perWorker;
    if (affordable < 1) {
      affordable = 1;
    }
    if (count > affordable) {
      count = affordable;
    }
  }

  return count;
}

/// One unit of work handed to a worker.
class _Job {
  final int kind;

  /// The whole archive, when it is in memory. Only [offset]..[offset]+[length]
  /// is sent to the worker.
  final Uint8List? bytes;

  final String? path;
  final int offset;
  final int length;
  final int streamFlags;
  final int outputOffset;
  final bool verify;
  final int maxPreallocateSize;
  final int maxDictionarySize;
  final int fileReadBufferSize;
  final int? uncompressedLength;
  final int? unpaddedLength;

  const _Job({
    required this.kind,
    required this.bytes,
    required this.path,
    required this.offset,
    required this.length,
    required this.streamFlags,
    required this.outputOffset,
    required this.verify,
    required this.maxPreallocateSize,
    this.maxDictionarySize = xzDefaultMaxDictionarySize,
    required this.fileReadBufferSize,
    this.uncompressedLength,
    this.unpaddedLength,
  });

  /// Builds the message for this job.
  ///
  /// The copy into external memory happens here rather than up front, so that
  /// only the blocks actually in flight are held: a queued job costs nothing
  /// beyond a view onto the archive the caller already has.
  List<Object?> toMessage() {
    TransferableTypedData? data;
    final source = bytes;
    if (source != null) {
      data = TransferableTypedData.fromList(
          [Uint8List.sublistView(source, offset, offset + length)]);
    }
    return [
      _kindMarker,
      kind,
      data,
      path,
      offset,
      length,
      streamFlags,
      outputOffset,
      verify,
      fileReadBufferSize,
      maxPreallocateSize,
      uncompressedLength,
      unpaddedLength,
      maxDictionarySize,
    ];
  }

  // Slot 0 of a job message is unused; workers only ever receive jobs, so it
  // carries no tag. Kept so main-bound and worker-bound messages index alike.
  static const _kindMarker = 0;
}

Future<bool> _runJobs(
    List<_Job> jobs,
    int workerCount,
    void Function(int outputOffset, Uint8List chunk) onChunk,
    void Function(int block, bool ok)? onBlockDone,
    void Function(String reason)? onFailureReason,
    [int? memoryBudget,
    int? maxAhead]) async {
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final completer = Completer<bool>();
  final pending = Queue<int>()..addAll(Iterable<int>.generate(jobs.length));
  final costs = List<int?>.filled(jobs.length, null);
  final costOf = <SendPort, int>{};
  final jobOf = <SendPort, int>{};
  final idle = <SendPort>[];
  var inFlight = 0;
  final done = List<bool>.filled(jobs.length, false);
  var firstUnfinished = 0;
  RandomAccessFile? headerFile;

  int costOfJob(int index) {
    final cached = costs[index];
    if (cached != null) {
      return cached;
    }
    final job = jobs[index];
    var dictionary = 0;
    try {
      final length =
          job.length < _maxBlockHeaderSize ? job.length : _maxBlockHeaderSize;
      final bytes = job.bytes;
      final Uint8List header;
      if (bytes != null) {
        header = Uint8List.sublistView(bytes, job.offset, job.offset + length);
      } else {
        final file = headerFile ??= File(job.path!).openSync();
        file.setPositionSync(job.offset);
        header = file.readSync(length);
      }
      final size = xzBlockDictionarySize(header);
      if (size > 0 && size < 0x40000000) {
        dictionary = xzDictionaryCap(size);
      }
    } catch (_) {
      // Unreadable header costs no dictionary, worker reports damaged block
    }
    final uncompressed = job.uncompressedLength ?? xzStagingSize;
    final held = job.bytes != null ? job.length : job.fileReadBufferSize;
    return costs[index] = held +
        dictionary +
        (uncompressed < xzStagingSize ? uncompressed : xzStagingSize);
  }

  // Worker count used dictionary of first 16 blocks only, so 20 `xz -0`
  // blocks before `xz -9` ones held ~2x 128 MiB budget. Like liblzma
  // memlimit_threading, each job waits until it fits, job over budget runs
  // alone
  void dispatch() {
    while (idle.isNotEmpty &&
        pending.isNotEmpty &&
        (maxAhead == null || pending.first < firstUnfinished + maxAhead)) {
      final budget = memoryBudget;
      final cost = budget == null ? 0 : costOfJob(pending.first);
      if (budget != null && inFlight > 0 && inFlight + cost > budget) {
        return;
      }
      final port = idle.removeLast();
      inFlight += cost;
      costOf[port] = cost;
      final job = pending.removeFirst();
      jobOf[port] = job;
      port.send(jobs[job].toMessage());
    }
  }

  var remaining = jobs.length;
  var ok = true;
  String? failureReason;
  Object? failure;
  StackTrace? failureStack;
  int? failedJob;
  String? indexReason;
  int? indexJob;
  var finished = false;

  void finish() {
    if (finished) {
      return;
    }
    finished = true;
    receive.close();
    try {
      headerFile?.closeSync();
    } catch (_) {}
    // Killing outright is safe because a worker holds no operating system
    // resources between jobs: it opens and closes the archive within one.
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    failureReason ??= failedJob == null ? indexReason : null;
    if (failureReason != null) {
      onFailureReason?.call(failureReason!);
    }
    if (failure != null) {
      completer.completeError(failure!, failureStack ?? StackTrace.current);
    } else {
      completer.complete(ok);
    }
  }

  void fail(Object error, [StackTrace? stack]) {
    failure ??= error;
    failureStack ??= stack;
    ok = false;
    finish();
  }

  receive.listen((message) {
    if (finished) {
      return;
    }
    try {
      // A dead isolate reports through the same port. Its message is a list
      // with no message tag in the first entry. Without this check the run
      // never completes
      if (message is! List || message.isEmpty || message[0] is! int) {
        fail(StateError('XZ decode isolate failed: $message'));
        return;
      }

      switch (message[0] as int) {
        case _msgChunk:
          onChunk(message[1] as int, message[2] as Uint8List);
          break;
        case _msgReady:
        case _msgDone:
          if (message[0] == _msgDone) {
            final blockOk = message[2] as bool;
            if (!blockOk) {
              ok = false;
            }
            final job = jobOf.remove(message[1] as SendPort);
            if (job != null) {
              onBlockDone?.call(job, blockOk);
              done[job] = true;
              while (firstUnfinished < jobs.length && done[firstUnfinished]) {
                firstUnfinished++;
              }
            }
            if (blockOk && message[5] != null) {
              ok = false;
              if (job != null && (indexJob == null || job < indexJob!)) {
                indexJob = job;
                indexReason = message[5] as String;
              }
            }
            final error = message[3];
            if (!blockOk &&
                (failedJob == null || (job != null && job < failedJob!))) {
              failedJob = job ?? jobs.length;
              // The first block to be rejected is the one worth reporting:
              // later ones may only be failing because this one did.
              final reason = message[5];
              failureReason = reason as String?;
              final thrown = message[6];
              failure = thrown ??
                  (error == null
                      ? null
                      : StateError('XZ decode failed: $error'));
            }
            // The output ends at the first failed block
            if (!blockOk || error != null) {
              remaining -= pending.length;
              pending.clear();
            }
            remaining--;
            if (remaining == 0) {
              finish();
              return;
            }
          }
          final port = message[1] as SendPort;
          inFlight -= costOf.remove(port) ?? 0;
          idle.add(port);
          dispatch();
          break;
      }
    } catch (error, stack) {
      fail(error, stack);
    }
  });

  try {
    for (var i = 0; i < workerCount; i++) {
      // A fast worker can get through every job before the rest of the pool
      // has even started, so the run can already be over by now.
      if (finished) {
        break;
      }
      isolates.add(await Isolate.spawn(_xzWorker, receive.sendPort,
          onError: receive.sendPort, errorsAreFatal: true));
    }
    if (finished) {
      // finish() only killed the isolates that existed when it ran.
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
  } catch (error, stack) {
    fail(error, stack);
  }

  return completer.future;
}

const _streamPieceSize = 1 << 16;

/// Worker offsets carry the block's place in the stream above these bits
const _idShift = 40;

/// Decodes an xz stream using isolates. Known-size blocks are offloaded to
/// background workers, while the rest are decoded locally to preserve output
/// order.
Stream<Uint8List> xzDecodeStreamMultithreaded(Stream<List<int>> input,
        {required bool verify, int? workers, int? memoryBudget}) =>
    cancellableStream<List<int>, Uint8List>(
        input,
        (input, signal) => _xzDecodeStream(input, signal,
            verify: verify, workers: workers, memoryBudget: memoryBudget));

Stream<Uint8List> _xzDecodeStream(
    StreamIterator<List<int>> input, CancelSignal signal,
    {required bool verify, int? workers, int? memoryBudget}) async* {
  final budget = memoryBudget ?? xzDefaultMemoryBudget;
  final ready = _Ready();
  final dispatch = _StreamDispatch(budget);
  final parser =
      xzChunkedDecoderWithDispatch(_QueueSink(ready), dispatch, verify: verify)
        ..unitAtATime = true;
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final idleWorkers = <SendPort>[];
  var pool = 0;
  var inFlight = 0;

  /// Spawned and not yet reported ready
  var starting = 0;
  Completer<void>? waiting;
  Object? failure;
  StackTrace? failureStack;
  Object? parseFailure;
  StackTrace? parseStack;

  void wake() {
    final waiter = waiting;
    if (waiter != null && !waiter.isCompleted) {
      waiting = null;
      waiter.complete();
    }
  }

  signal.onCancel = wake;

  // Outputs only fully validated blocks. On failure, we just get the good
  // blocks that came before it
  void release() {
    while (dispatch.records.isNotEmpty) {
      final head = dispatch.records.first;
      if (!head.done) {
        return;
      }
      if (!head.ok) {
        final message = 'xz: ${head.reason ?? 'a block failed'}';
        failure ??= xzIsLimitFailure(head.reason)
            ? ArchiveLimitException(message)
            : xzCheckFailures.contains(head.reason)
                ? ArchiveChecksumException(message)
                : ArchiveException(message);
        return;
      }
      for (final piece in head.pieces) {
        for (var at = 0; at < piece.length; at += _streamPieceSize) {
          final end = at + _streamPieceSize < piece.length
              ? at + _streamPieceSize
              : piece.length;
          ready.add(Uint8List.sublistView(piece, at, end));
        }
      }
      head.pieces.clear();
      dispatch.records.removeFirst();
      dispatch.byId.remove(head.id);
      inFlight -= head.cost;
    }
  }

  // A worker decodes a whole block before it sends anything, so a pause cannot
  // stop that block part way. While this much decoded output is queued the
  // consumer is behind, and the blocks not yet sent stay compressed
  const aheadMax = 1 << 20;

  void pump() {
    // Pool size from block 0 alone let 64 MiB blocks after small ones hold
    // 1.2 GB under 256 MiB budget, so like liblzma memlimit_threading each
    // block waits until it fits. Block over budget runs alone, as in liblzma
    while (idleWorkers.isNotEmpty &&
        dispatch.unsent.isNotEmpty &&
        ready.bytes < aheadMax &&
        (inFlight == 0 || inFlight + dispatch.unsent.first.cost <= budget)) {
      final record = dispatch.unsent.removeFirst();
      inFlight += record.cost;
      final bytes = record.bytes!;
      record.bytes = null;
      idleWorkers.removeLast().send(_Job(
            kind: xzKindBlock,
            bytes: bytes,
            path: null,
            offset: 0,
            length: bytes.length,
            streamFlags: record.streamFlags,
            outputOffset: record.id << _idShift,
            verify: verify,
            maxPreallocateSize: budget,
            fileReadBufferSize: 0,
            uncompressedLength: record.uncompressedLength,
          ).toMessage());
    }
  }

  receive.listen((message) {
    try {
      if (message is! List || message.isEmpty || message[0] is! int) {
        failure ??= StateError('XZ decode isolate failed: $message');
      } else if (message[0] == _msgChunk) {
        final id = (message[1] as int) >> _idShift;
        dispatch.byId[id]?.pieces.add(message[2] as Uint8List);
        release();
      } else {
        if (message[0] == _msgReady) {
          starting--;
        } else if (message[0] == _msgDone) {
          final id = (message[4] as int) >> _idShift;
          final record = dispatch.byId[id];
          if (record != null) {
            record
              ..done = true
              ..ok = message[2] as bool && message[3] == null
              ..reason = message[5] as String? ?? message[3] as String?;
          }
          final thrown = message[6];
          if (thrown != null) {
            failure ??= thrown;
          }
        }
        idleWorkers.add(message[1] as SendPort);
        pump();
        release();
      }
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    wake();
  });

  /// Spawns a worker per waiting block so they process immediately.
  /// If a spawn fails, the whole decode aborts (should not really happen)
  Future<void> grow() async {
    if (dispatch.unsent.isEmpty) {
      return;
    }
    if (pool == 0) {
      final cores = Platform.numberOfProcessors;
      var count = workers ?? cores - 1;
      if (count > cores) {
        count = cores;
      }
      if (count < 1) {
        count = 1;
      }
      // compressed bytes, dictionary, staging and one held decoded block
      final affordable = budget ~/ dispatch.perWorker;
      if (count > affordable) {
        count = affordable < 1 ? 1 : affordable;
      }
      pool = count;
    }
    while (failure == null &&
        dispatch.unsent.length > idleWorkers.length + starting &&
        isolates.length < pool) {
      starting++;
      try {
        isolates.add(await Isolate.spawn(_xzWorker, receive.sendPort,
            onError: receive.sendPort, errorsAreFatal: true));
      } catch (error, stack) {
        starting--;
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }

  // Feeds the pool after every step, even on failures. A step might output
  // the final blocks and then crash on the index
  bool parse(void Function() run) {
    try {
      run();
      return true;
    } catch (error, stack) {
      parseFailure ??= error;
      parseStack ??= stack;
      return false;
    } finally {
      pump();
    }
  }

  Stream<Uint8List> drain() async* {
    while (
        failure == null && !signal.cancelled && dispatch.records.isNotEmpty) {
      await grow();
      pump();
      while (ready.isNotEmpty) {
        yield ready.removeFirst();
      }
      // pump stops while the queue is full, so it runs again once the queue is
      // empty: the wait below ends on a message from a worker, and a pump that
      // stopped can leave every worker idle
      pump();
      if (failure == null && dispatch.records.isNotEmpty) {
        waiting = Completer<void>();
        await waiting!.future;
      }
    }
    while (ready.isNotEmpty) {
      yield ready.removeFirst();
    }
  }

  // We only hold as many blocks as the pool can handle. If we parse a block
  // locally, we wait until the previous ones are out
  Stream<Uint8List> settle() async* {
    while (failure == null && parseFailure == null && !signal.cancelled) {
      await grow();
      pump();
      if (failure != null) {
        return;
      }
      if (parser.waitingForIdle) {
        yield* drain();
        if (failure != null || !parse(parser.resume)) {
          return;
        }
        continue;
      }
      while (ready.isNotEmpty) {
        yield ready.removeFirst();
      }
      pump();
      if (pool == 0 || dispatch.records.length < pool) {
        return;
      }
      waiting = Completer<void>();
      await waiting!.future;
    }
  }

  final ahead = InputAhead<List<int>>(input, wake);
  try {
    try {
      while (true) {
        ahead.ask();
        while (!ahead.arrived && failure == null && !signal.cancelled) {
          while (ready.isNotEmpty) {
            yield ready.removeFirst();
          }
          pump();
          if (ahead.arrived || failure != null || signal.cancelled) {
            break;
          }
          waiting = Completer<void>();
          await waiting!.future;
        }
        if (failure != null || signal.cancelled) {
          break;
        }
        final chunk = ahead.take();
        if (chunk == null) {
          break;
        }
        if (!parse(() => parser.add(chunk))) {
          break;
        }
        yield* settle();
        while (failure == null &&
            parseFailure == null &&
            !signal.cancelled &&
            parser.available > 0 &&
            !parser.waitingForIdle) {
          final consumed = parser.consumed;
          if (!parse(parser.resume)) {
            break;
          }
          yield* settle();
          if (parser.consumed == consumed) {
            break;
          }
        }
        if (failure != null || parseFailure != null || signal.cancelled) {
          break;
        }
      }
    } catch (error, stack) {
      parseFailure ??= error;
      parseStack ??= stack;
    }
    if (signal.cancelled) {
      return;
    }
    if (failure == null && parseFailure == null) {
      yield* drain();
      while (failure == null && parser.waitingForIdle && parse(parser.resume)) {
        yield* drain();
      }
      if (failure == null && parseFailure == null) {
        parse(parser.close);
      }
    }
    // Blocks queued before a failure in the parse are still written out
    yield* drain();
    final thrown = failure ?? parseFailure;
    if (thrown != null) {
      Error.throwWithStackTrace(
          thrown,
          (identical(thrown, failure) ? failureStack : parseStack) ??
              StackTrace.current);
    }
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
    // Leaving early, on a failure or a cancel, still lets go of the input
    await input.cancel();
  }
}

class _StreamBlock {
  final int id;
  final int streamFlags;
  final int uncompressedLength;

  /// Cleared once the block is on its way to a worker
  Uint8List? bytes;
  final pieces = <Uint8List>[];
  var done = false;
  var ok = false;
  String? reason;
  var cost = 0;

  _StreamBlock(this.id, this.bytes, this.streamFlags, this.uncompressedLength);
}

class _StreamDispatch implements XzBlockDispatch {
  final int _maxBlockBytes;

  /// Past 2^23 blocks `id << _idShift` overflows and converter hangs, so
  /// parser decodes later blocks itself
  @override
  int get maxBlockBytes => _next < 1 << (63 - _idShift) ? _maxBlockBytes : -1;

  /// Queued and not yet written out, in stream order
  final records = ListQueue<_StreamBlock>();
  final unsent = ListQueue<_StreamBlock>();
  final byId = <int, _StreamBlock>{};
  var _next = 0;
  var perWorker = 1;

  _StreamDispatch(this._maxBlockBytes);

  @override
  bool get idle => records.isEmpty;

  @override
  void block(Uint8List bytes, int streamFlags, int uncompressedLength,
      int dictionarySize) {
    final record =
        _StreamBlock(_next++, bytes, streamFlags, uncompressedLength);
    records.add(record);
    unsent.add(record);
    byId[record.id] = record;
    record.cost = bytes.length +
        (dictionarySize > 0 && dictionarySize < 0x40000000
            ? xzDictionaryCap(dictionarySize)
            : 0) +
        (uncompressedLength < xzStagingSize
            ? uncompressedLength
            : xzStagingSize) +
        uncompressedLength;
    if (record.id == 0) {
      final dictionary = dictionarySize > 0 && dictionarySize < 0x40000000
          ? xzDictionaryCap(dictionarySize)
          : 0;
      perWorker =
          bytes.length + dictionary + xzStagingSize + uncompressedLength;
    }
  }
}

class _QueueSink implements Sink<List<int>> {
  final _Ready _ready;

  _QueueSink(this._ready);

  @override
  void add(List<int> data) =>
      _ready.add(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void close() {}
}

/// The decoded pieces waiting for the consumer. `pump` compares [bytes] with
/// its limit before it sends another block
class _Ready {
  final _queue = ListQueue<Uint8List>();
  var bytes = 0;

  bool get isEmpty => _queue.isEmpty;

  bool get isNotEmpty => _queue.isNotEmpty;

  void add(Uint8List piece) {
    _queue.add(piece);
    bytes += piece.length;
  }

  Uint8List removeFirst() {
    final piece = _queue.removeFirst();
    bytes -= piece.length;
    return piece;
  }
}

/// Reads the check field, the tail of a block.
///
/// The block padding sits in front of it and every check size is a multiple of
/// four, so the check is always the last [checkSize] bytes.
Uint8List _readCheckField(
    InputStream input, Uint8List? data, int length, int checkSize) {
  if (checkSize == 0 || length < checkSize) {
    return Uint8List(0);
  }
  if (data != null) {
    return Uint8List.sublistView(data, length - checkSize, length);
  }
  input.setPosition(length - checkSize);
  return input.readBytes(checkSize).toUint8List();
}

/// Entry point of a decode worker.
///
/// A worker outlives a single block: the pool hands it one job after another,
/// which keeps the hot LZMA loop warm. That matters under the JIT, where a
/// freshly spawned isolate has to optimise it all over again.
void _xzWorker(SendPort toMain) {
  final receive = ReceivePort();

  receive.listen((message) {
    if (message == null) {
      receive.close();
      return;
    }

    final job = message as List;
    final kind = job[1] as int;
    final transferable = job[2] as TransferableTypedData?;
    final path = job[3] as String?;
    final offset = job[4] as int;
    final length = job[5] as int;
    final streamFlags = job[6] as int;
    final outputOffset = job[7] as int;
    final verify = job[8] as bool;
    final fileReadBufferSize = job[9] as int;
    final maxPreallocateSize = job[10] as int;
    final uncompressedLength = job[11] as int?;
    final unpaddedLength = job[12] as int?;
    final maxDictionarySize = job[13] as int;

    // Failing to get hold of the compressed data is a failure of the decode
    // itself rather than a statement about the archive, so it is reported as
    // an error. Afterwards only a data error is the archive's fault.
    Uint8List? data;
    InputFileStream? file;
    InputStream input;
    try {
      if (transferable != null) {
        // Materialising is free: the bytes are already in external memory and
        // this hands over ownership of them.
        data = Uint8List.view(transferable.materialize());
        input = InputMemoryStream(data);
      } else {
        // Read the block as it is decoded rather than up front. LZMA2 reads a
        // block strictly in order, so nothing is gained by holding all of it,
        // and a compressed block is the largest thing a worker would otherwise
        // keep.
        file = InputFileStream(path!, bufferSize: fileReadBufferSize);
        input = InputFileStream.fromFileStream(file,
            position: offset, length: length);
      }
    } catch (error) {
      if (!isDecodeDataError(error)) {
        _sendThrown(toMain, receive.sendPort, outputOffset, error);
        return;
      }
      toMain.send([
        _msgDone,
        receive.sendPort,
        false,
        error.toString(),
        outputOffset,
        null,
        null
      ]);
      return;
    }

    final ({bool ok, String? reason}) result;
    try {
      result = xzDecodeJob(
          kind: kind,
          input: input,
          data: data,
          length: length,
          streamFlags: streamFlags,
          verify: verify,
          maxPreallocateSize: maxPreallocateSize,
          maxDictionarySize: maxDictionarySize,
          outputOffset: outputOffset,
          uncompressedLength: uncompressedLength,
          unpaddedLength: unpaddedLength,
          onPiece: (at, piece) => toMain.send([_msgChunk, at, piece]));
    } catch (error) {
      file?.closeSync();
      _sendThrown(toMain, receive.sendPort, outputOffset, error);
      return;
    }
    file?.closeSync();
    toMain.send([
      _msgDone,
      receive.sendPort,
      result.ok,
      null,
      outputOffset,
      result.reason,
      null
    ]);
  });

  toMain.send([_msgReady, receive.sendPort, null, null, -1, null]);
}

void _sendThrown(
    SendPort toMain, SendPort worker, int outputOffset, Object error) {
  final message = [
    _msgDone,
    worker,
    false,
    error.toString(),
    outputOffset,
    null,
    error
  ];
  try {
    toMain.send(message);
  } catch (_) {
    message[6] = null;
    toMain.send(message);
  }
}

/// Decodes one job into pieces passed to [onPiece] and checks a block against
/// the field it ends with. A corrupt archive is not a throw!
({bool ok, String? reason}) xzDecodeJob({
  required int kind,
  required InputStream input,
  required Uint8List? data,
  required int length,
  required int streamFlags,
  required bool verify,
  required int maxPreallocateSize,
  int maxDictionarySize = xzDefaultMaxDictionarySize,
  required int outputOffset,
  required int? uncompressedLength,
  required int? unpaddedLength,
  required void Function(int offset, Uint8List piece) onPiece,
}) {
  var ok = false;
  String? reason;
  var decodedUnpadded = -1;
  final checkType = streamFlags & 0xf;
  // Verifying never holds the whole block
  final verifyHere = verify && kind == xzKindBlock;
  // Zeroing 4 MiB for every block cost ~720 µs per 1-byte block, so buffer
  // stops at block size
  final stagingSize =
      uncompressedLength != null && uncompressedLength < xzStagingSize
          ? (uncompressedLength < 1 ? 1 : uncompressedLength)
          : xzStagingSize;
  var sent = 0;
  void bounded(int at, Uint8List piece) {
    final room =
        uncompressedLength == null ? piece.length : uncompressedLength - sent;
    final keep = piece.length < room ? piece.length : (room < 0 ? 0 : room);
    sent += keep;
    if (keep > 0) {
      onPiece(at,
          keep == piece.length ? piece : Uint8List.sublistView(piece, 0, keep));
    }
  }

  final sink = XzBlockSink(bounded, outputOffset, verifyHere ? checkType : 0,
      stagingSize: stagingSize);
  try {
    if (kind == xzKindBlock) {
      final result = decodeXZBlock(input, streamFlags, sink,
          maxPreallocateSize: maxPreallocateSize,
          verify: verify,
          maxDictionarySize: maxDictionarySize);
      ok = result.ok;
      reason = result.reason;
      decodedUnpadded = result.unpaddedLength;
    } else {
      final decoder = XZStreamDecoder(
          verify: verify,
          maxPreallocateSize: maxPreallocateSize,
          maxDictionarySize: maxDictionarySize);
      ok = decoder.decode(input, sink);
      reason = decoder.failureReason;
    }
  } catch (error) {
    if (!isDecodeDataError(error)) {
      rethrow;
    }
    ok = false;
    reason = '$error';
  } finally {
    // What decoded before a failure is kept, as the single threaded path does
    try {
      sink.flush();
    } catch (error) {
      ok = false;
      reason ??= '$error';
    }
  }
  if (ok && unpaddedLength != null && decodedUnpadded != unpaddedLength) {
    reason = 'Stream index compressed length mismatch';
  }
  // Block shorter than its index entry left zeros in decodeBytes output and
  // made decodeStream stop early with success, so we fail such block here
  if (ok && uncompressedLength != null && sink.length != uncompressedLength) {
    ok = false;
    reason = 'Stream index uncompressed length mismatch';
  }
  if (ok && verifyHere) {
    try {
      ok = sink.checkMatches(
          _readCheckField(input, data, length, xzCheckSize(checkType)));
      if (!ok) {
        reason = xzBlockCheckFailed;
      }
    } catch (error) {
      if (!isDecodeDataError(error)) {
        rethrow;
      }
      ok = false;
      reason = '$error';
    }
  }
  return (ok: ok, reason: reason);
}

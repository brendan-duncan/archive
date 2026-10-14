import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// The io file handle is imported directly rather than through
// file_handle.dart, whose conditional export resolves to the web class when
// the analyser has no platform in mind, and that one has no path
import '../../util/_file_handle_io.dart';
import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/input_file_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/report_progress.dart';
import '../../util/xxh64.dart';
import 'zstd_dictionary.dart';
import 'zstd_level_params.dart';
import 'zstd_mt_frame_encoder.dart';

const bool zstdIsolatesSupported = true;

const _streamPieceSize = 1 << 16;

/// Starts one worker. A test swaps it to make a spawn fail
Future<Isolate> Function(SendPort replies, SendPort errors) zstdMtSpawnWorker =
    (replies, errors) => Isolate.spawn(_zstdMtWorker, replies,
        onError: errors, errorsAreFatal: true);

/// Compresses every job on an isolate, at most [workers] at a time, and
/// returns their output in job order. A job has its own prefix, so nothing
/// is shared and the bytes do not depend on how many run at once.
///
/// The workers are spawned once and reused for every job: a fresh isolate per
/// job costs a heap and a set of tables each time. That made the memory grow
/// with the job count rather than with the pool
Future<List<Uint8List>> zstdMtCompressJobs(
    Uint8List src, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    bool firstIsFirstJob = true,
    int size = 0,
    int paramsSize = 0,
    ZstdMtLdmPass? ldmPass,
    void Function(int consumed)? onProgress}) {
  // The job is copied out of the shared input once and then moved rather than
  // copied again: a message holding a Uint8List is serialised on its way to
  // the isolate, a transfer is not
  Object source(int start, int end, int prefix) =>
      TransferableTypedData.fromList([
        Uint8List.fromList(Uint8List.sublistView(src, start - prefix, end))
      ]);
  final whole = size > 0 ? size : src.length;
  // With a dictionary the parameters are sized by more than the content, and
  // the long distance pass has already run over job zero
  final sized = paramsSize > 0 ? paramsSize : whole;
  // `ZSTDMT_serialState_reset` sizes the matcher by `targetSectionSize`, the
  // job size after the minimum and the prefix raised it. Sizing it by the
  // number given here left the sequence pool at 31 matches a job, not 16384
  final pass = ldmPass ??
      ZstdMtLdmPass.forParams(
          zstdParamsForLevel(level, sized),
          ZstdMtFrameEncoder.geometry(level, sized,
              jobSize: jobSize, overlapLog: overlapLog)[0]);
  return _compress(starts, prefixSize, whole, level, source,
      jobSize: jobSize,
      overlapLog: overlapLog,
      workers: workers,
      cap: cap,
      firstIsFirstJob: firstIsFirstJob,
      paramsSize: sized,
      ldmFor: pass == null
          ? null
          : (start, end) => zstdMtPackLdm(pass.generate(src, start, end)),
      onProgress: onProgress);
}

/// As [zstdMtCompressJobs], with each job read from the file itself, so the
/// input never sits in the calling isolate
Future<List<Uint8List>> zstdMtCompressFileJobs(String path, int offset,
    int size, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    void Function(Uint8List part)? onPart,
    void Function(int consumed)? onProgress}) async {
  Object source(int start, int end, int prefix) =>
      [path, offset + start - prefix, prefix + (end - start)];
  final pass = ZstdMtLdmPass.forParams(
      zstdParamsForLevel(level, size),
      ZstdMtFrameEncoder.geometry(level, size,
          jobSize: jobSize, overlapLog: overlapLog)[0]);
  // The workers read their own slices, so the one serial pass reads the file
  // here rather than sharing their buffers
  final handle = pass == null ? null : File(path).openSync();
  List<Object>? ldmFor(int start, int end) {
    final reader = handle!;
    reader.setPositionSync(offset + start);
    return zstdMtPackLdm(
        pass!.generate(reader.readSync(end - start), 0, end - start));
  }

  try {
    return await _compress(starts, prefixSize, size, level, source,
        jobSize: jobSize,
        overlapLog: overlapLog,
        workers: workers,
        cap: cap,
        ldmFor: pass == null ? null : ldmFor,
        onPart: onPart,
        onProgress: onProgress);
  } finally {
    handle?.closeSync();
  }
}

/// The frame's checksum, taken over the file in one pass rather than over a
/// copy in memory. The jobs cannot help with it: XXH64 does not combine
int zstdMtFileDigest(String path, int offset, int size) {
  final hash = Xxh64()..reset();
  final file = File(path).openSync();
  try {
    file.setPositionSync(offset);
    final buffer = Uint8List(1 << 20);
    var left = size;
    while (left > 0) {
      final want = left < buffer.length ? left : buffer.length;
      final got = file.readIntoSync(buffer, 0, want);
      if (got <= 0) {
        break;
      }
      hash.update(buffer, 0, got);
      left -= got;
    }
  } finally {
    file.closeSync();
  }
  return hash.digestLow;
}

/// The file [input] reads from, as path, offset and length, or null when it is
/// not backed by one
List<Object>? zstdMtFileRegion(InputStream input) {
  if (input is! InputFileStream) {
    return null;
  }
  final handle = input.fileBuffer.file;
  if (handle is! FileHandle) {
    return null;
  }
  return [handle.path, input.fileOffset + input.position, input.length];
}

Future<List<Uint8List>> _compress(List<int> starts, int prefixSize, int size,
    int level, Object Function(int start, int end, int prefix) source,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    required int cap,
    bool firstIsFirstJob = true,
    int paramsSize = 0,
    List<Object>? Function(int start, int end)? ldmFor,
    void Function(Uint8List part)? onPart,
    void Function(int consumed)? onProgress}) async {
  final parts = List<Uint8List?>.filled(starts.length, null);
  var pool = zstdMtPoolSize(workers, Platform.numberOfProcessors, cap);
  if (pool > starts.length) {
    pool = starts.length;
  }
  if (pool < 1) {
    pool = 1;
  }

  final receive = ReceivePort();
  final done = Completer<void>();
  final isolates = <Isolate>[];
  final held = <int, Uint8List>{};
  var written = 0;
  var next = 0;
  var left = starts.length;
  var completed = 0;
  final partial = <int, int>{};
  void report() => reportProgress(onProgress,
      starts[0] + completed + partial.values.fold<int>(0, (a, b) => a + b));
  Object? failure;
  StackTrace? failureStack;

  /// Workers that get no job while [ahead] jobs are already sent out
  final parked = <SendPort>[];

  /// How many jobs may be sent out beyond the part written next. A job that
  /// finishes early holds its part until its turn, so the pool holds up to
  /// this many parts above the job buffers. `ZSTDMT_createCompressionJob`
  /// stops at `nbWorkers + 2`, and stopping at the worker count would idle the
  /// pool behind one slow job.
  final ahead = pool + 2;

  void give(SendPort worker) {
    if (next >= starts.length) {
      worker.send(null);
      return;
    }
    final index = next++;
    final start = starts[index];
    final end = index + 1 < starts.length ? starts[index + 1] : size;
    final prefix = start < prefixSize ? start : prefixSize;
    worker.send([
      index,
      source(start, end, prefix),
      prefix,
      level,
      paramsSize > 0 ? paramsSize : size,
      index == 0 && firstIsFirstJob,
      index == starts.length - 1,
      jobSize,
      overlapLog,
      // In job order, the order the one long distance pass over the frame
      // needs. `give` sends the jobs in that order, whichever finishes first
      ldmFor?.call(start, end),
      onProgress != null,
    ]);
  }

  final errors = ReceivePort();
  errors.listen((message) {
    final pair = message as List;
    failure ??= ArchiveException('zstd: ${pair[0]}');
    failureStack ??= StackTrace.fromString('${pair[1]}');
    if (!done.isCompleted) {
      done.complete();
    }
  });

  void handleReply(Object? message) {
    if (message is SendPort) {
      give(message);
      return;
    }
    final reply = message as List;
    if (reply.length == 2) {
      partial[reply[0] as int] = reply[1] as int;
      report();
      return;
    }
    final worker = reply[0] as SendPort;
    final index = reply[1] as int;
    final error = reply[3];
    if (error != null) {
      failure ??= ArchiveException('zstd: $error');
      failureStack ??= StackTrace.fromString(reply[4] as String);
    } else {
      final part =
          (reply[2] as TransferableTypedData).materialize().asUint8List();
      if (onPart == null) {
        parts[index] = part;
      } else {
        // Only the parts that ran ahead of their turn are held, the rest go
        // straight out, so a frame of any size costs the pool and not itself
        held[index] = part;
        // A write to the output that throws is reported as this encode's
        // failure. Uncaught here it would leave through
        // this port's zone instead, where the call has nothing listening
        try {
          while (failure == null && held.containsKey(written)) {
            onPart(held.remove(written)!);
            written++;
          }
        } catch (thrown, stack) {
          failure ??= thrown;
          failureStack ??= stack;
        }
      }
      partial.remove(index);
      completed += (index + 1 < starts.length ? starts[index + 1] : size) -
          starts[index];
      report();
    }
    left--;
    // A failed job loses the frame. No more jobs go out after it
    if (left == 0 || failure != null) {
      if (!done.isCompleted) {
        done.complete();
      }
      return;
    }
    while (parked.isNotEmpty && next - written < ahead) {
      give(parked.removeLast());
    }
    if (onPart != null && next - written >= ahead) {
      parked.add(worker);
      return;
    }
    give(worker);
  }

  receive.listen((message) {
    // Anything thrown here would leave through this port's zone, where the
    // call has nothing listening, and `left` would never reach zero
    try {
      handleReply(message);
    } catch (thrown, stack) {
      failure ??= thrown;
      failureStack ??= stack;
      if (!done.isCompleted) {
        done.complete();
      }
    }
  });

  try {
    for (var i = 0; i < pool; i++) {
      // A dead isolate must not arrive on the port the replies come in on:
      // `[error, stack]` read as a reply is a cast that hangs the pool
      isolates.add(await zstdMtSpawnWorker(receive.sendPort, errors.sendPort));
    }
    await done.future;
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
    errors.close();
  }

  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
  }
  if (onPart != null) {
    return const [];
  }
  return [for (final part in parts) part!];
}

/// The compressed parts of [input], in job order, with the jobs cut out of the
/// bytes as they arrive and sent to a pool of at most [workers]. The header
/// and the checksum are not included, as everywhere else here
Stream<Uint8List> zstdMtCompressStream(Stream<List<int>> input, int level,
        {required int jobSize,
        required int overlapLog,
        required int workers,
        int cap = 0,
        ZstdDictionary? dictionary,
        Uint8List Function(bool empty)? header,
        int size = zstdMtSizeUnknown,
        void Function(int consumed)? onProgress}) =>
    cancellableStream<List<int>, Uint8List>(
        input,
        (input, signal) => _zstdMtCompressStream(input, signal, level,
            jobSize: jobSize,
            overlapLog: overlapLog,
            workers: workers,
            cap: cap,
            dictionary: dictionary,
            header: header,
            size: size,
            onProgress: onProgress));

Stream<Uint8List> _zstdMtCompressStream(
    StreamIterator<List<int>> input, CancelSignal signal, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    ZstdDictionary? dictionary,
    Uint8List Function(bool empty)? header,
    int size = zstdMtSizeUnknown,
    void Function(int consumed)? onProgress}) async* {
  final geometry = ZstdMtFrameEncoder.geometry(level, size,
      jobSize: jobSize, overlapLog: overlapLog);
  final ring = ZstdMtRing(geometry[0], geometry[1]);
  // One long distance pass over the whole frame, run here in job order, with
  // its matches passed to each job. A job sees only its own prefix and cannot
  // find them itself
  final ldmPass =
      ZstdMtLdmPass.forParams(zstdParamsForLevel(level, size), geometry[0]);
  final pool = zstdMtPoolSize(workers, Platform.numberOfProcessors, cap);

  // The workers are spawned once and reused for every job, as everywhere else
  // here: an isolate per job costs a new heap and table set each time
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final idle = <SendPort>[];
  final queued = <List<Object?>>[];
  final held = <int, Uint8List>{};

  /// Parts whose turn has come, waiting for the consumer to take them. The
  /// generator below is the only thing that empties it. The reading follows the
  /// consumer's pace that way
  final ready = <Uint8List>[];
  var written = 0;
  var sent = 0;
  var back = 0;
  final inputOf = <int, int>{};
  final partialOf = <int, int>{};
  var consumed = 0;
  void reportStream() => reportProgress(
      onProgress, consumed + partialOf.values.fold<int>(0, (a, b) => a + b));
  void finishJob(int index) {
    partialOf.remove(index);
    consumed += inputOf.remove(index) ?? 0;
    reportStream();
  }

  /// How many jobs may be sent out beyond the part written next. Counting
  /// the replies instead would hold the whole frame behind one slow job, so
  /// the gate below reads `written` and takes the reference's `nbWorkers + 2`
  final jobsAhead = pool + 2;
  // The frame header waits for the first part, since only by then is whether
  // anything arrived at all settled
  var content = 0;
  var headerSent = false;
  Completer<void>? waiting;
  Object? failure;
  StackTrace? failureStack;

  void hand(SendPort worker) {
    if (queued.isEmpty) {
      idle.add(worker);
      return;
    }
    worker.send(queued.removeAt(0));
  }

  void wake() {
    final waiter = waiting;
    if (waiter != null && !waiter.isCompleted) {
      waiting = null;
      waiter.complete();
    }
  }

  signal.onCancel = wake;

  void release() {
    while (held.containsKey(written)) {
      if (!headerSent) {
        headerSent = true;
        final head = header?.call(content == 0);
        if (head != null) {
          ready.add(head);
        }
      }
      final job = held.remove(written)!;
      if (job.length <= _streamPieceSize) {
        ready.add(job);
      } else {
        for (var at = 0; at < job.length; at += _streamPieceSize) {
          final end = at + _streamPieceSize < job.length
              ? at + _streamPieceSize
              : job.length;
          ready.add(Uint8List.sublistView(job, at, end));
        }
      }
      written++;
    }
  }

  final errors = ReceivePort();
  errors.listen((message) {
    final pair = message as List;
    failure ??= ArchiveException('zstd: ${pair[0]}');
    failureStack ??= StackTrace.fromString('${pair[1]}');
    // No further reply can arrive from a dead worker, so whoever is parked on
    // `waiting` has to be let go or the frame never ends
    wake();
  });

  void handleReply(Object? message) {
    if (message is SendPort) {
      hand(message);
      return;
    }
    final reply = message as List;
    if (reply.length == 2) {
      partialOf[reply[0] as int] = reply[1] as int;
      reportStream();
      return;
    }
    final worker = reply[0] as SendPort;
    final index = reply[1] as int;
    final error = reply[3];
    if (error != null) {
      failure ??= ArchiveException('zstd: $error');
      failureStack ??= StackTrace.fromString(reply[4] as String);
    } else {
      held[index] =
          (reply[2] as TransferableTypedData).materialize().asUint8List();
      finishJob(index);
      release();
    }
    back++;
    hand(worker);
    wake();
  }

  receive.listen((message) {
    // Anything thrown here would leave through this port's zone, where the
    // generator has nothing listening, and `back` would never catch `sent`
    try {
      handleReply(message);
    } catch (thrown, stack) {
      failure ??= thrown;
      failureStack ??= stack;
      wake();
    }
  });

  void submit(Uint8List job, int prefix, bool first, bool last) {
    inputOf[sent] = job.length - prefix;
    // The dictionary belongs to the first job and does not cross the port, so
    // that one is compressed here and takes its place in the order like any
    // other part
    if (first && dictionary != null) {
      final content = dictionary.content;
      final held0 = Uint8List(content.length + job.length)
        ..setRange(0, content.length, content)
        ..setRange(content.length, content.length + job.length, job);
      final out = OutputMemoryStream();
      ZstdMtFrameEncoder.encodeJob(held0, content.length, out, level, size,
          firstJob: true,
          lastJob: last,
          jobSize: jobSize,
          overlapLog: overlapLog,
          dictionary: dictionary,
          ldmSequences: ldmPass?.generate(job, prefix, job.length),
          onBlock: (done) {
        partialOf[sent] = done;
        reportStream();
      });
      held[sent] = out.getBytes();
      finishJob(sent);
      sent++;
      back++;
      release();
      return;
    }
    final message = <Object?>[
      sent,
      TransferableTypedData.fromList([job]),
      prefix,
      level,
      size,
      first,
      last,
      jobSize,
      overlapLog,
      zstdMtPackLdm(ldmPass?.generate(job, prefix, job.length)),
      onProgress != null,
    ];
    sent++;
    if (idle.isEmpty) {
      queued.add(message);
    } else {
      idle.removeAt(0).send(message);
    }
  }

  try {
    for (var i = 0; i < pool; i++) {
      // A dead isolate must not arrive on the port the replies come in on:
      // `[error, stack]` read as a reply is a cast that hangs the pool
      isolates.add(await zstdMtSpawnWorker(receive.sendPort, errors.sendPort));
    }

    // The reading happens here rather than beside it, so a consumer that pauses
    // pauses the input with it and a consumer that cancels cancels the input:
    // a generator suspended at a yield is not asking its source for anything
    final ahead = InputAhead<List<int>>(input, wake);
    while (true) {
      ahead.ask();
      while (!ahead.arrived && failure == null && !signal.cancelled) {
        while (ready.isNotEmpty) {
          yield ready.removeAt(0);
        }
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
      content += chunk.length;
      for (final job in ring.add(chunk)) {
        submit(job, sent == 0 ? 0 : geometry[1], sent == 0, false);
        while (ready.isNotEmpty) {
          yield ready.removeAt(0);
        }
        // No more jobs sent out than the pool may run ahead of the part
        // written next: each one holds its own buffer, so a looser gate costs
        // memory
        while (failure == null &&
            !signal.cancelled &&
            sent - written >= jobsAhead) {
          waiting = Completer<void>();
          await waiting!.future;
          while (ready.isNotEmpty) {
            yield ready.removeAt(0);
          }
        }
        if (failure != null || signal.cancelled) {
          break;
        }
      }
      if (failure != null || signal.cancelled) {
        break;
      }
    }
    if (signal.cancelled) {
      return;
    }
    if (failure == null) {
      submit(ring.close(), sent == 0 ? 0 : geometry[1], sent == 0, true);
    }
    while (failure == null && !signal.cancelled && back < sent) {
      while (ready.isNotEmpty) {
        yield ready.removeAt(0);
      }
      if (back < sent) {
        waiting = Completer<void>();
        await waiting!.future;
      }
    }
    while (ready.isNotEmpty) {
      yield ready.removeAt(0);
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
    }
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
    errors.close();
    // Leaving early, on a failure or a cancel, still lets go of the input
    await input.cancel();
  }
}

/// One worker: it takes job after job and keeps its heap between them
void _zstdMtWorker(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  port.listen((message) {
    if (message == null) {
      port.close();
      return;
    }
    final job = message as List;
    final index = job[0] as int;
    try {
      final source = job[1];
      final Uint8List buffer;
      if (source is TransferableTypedData) {
        buffer = source.materialize().asUint8List();
      } else {
        final region = source as List;
        final file = File(region[0] as String).openSync();
        try {
          file.setPositionSync(region[1] as int);
          buffer = file.readSync(region[2] as int);
        } finally {
          file.closeSync();
        }
      }
      final out = OutputMemoryStream();
      var reported = 0;
      ZstdMtFrameEncoder.encodeJob(
          buffer, job[2] as int, out, job[3] as int, job[4] as int,
          firstJob: job[5] as bool,
          lastJob: job[6] as bool,
          jobSize: job[7] as int,
          overlapLog: job[8] as int,
          ldmSequences: job.length > 9 ? zstdMtUnpackLdm(job[9]) : null,
          onBlock: job.length > 10 && job[10] == true
              ? (done) {
                  if (done - reported >= 1 << 20) {
                    reported = done;
                    toMain.send([index, done]);
                  }
                }
              : null);
      toMain.send([
        port.sendPort,
        index,
        TransferableTypedData.fromList([out.getBytes()]),
        null,
        null,
      ]);
    } catch (error, stack) {
      toMain.send([port.sendPort, index, null, '$error', '$stack']);
    }
  });
}

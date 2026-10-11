import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/zstd/_zstd_mt_parallel_io.dart'
    show
        zstdMtCompressFileJobs,
        zstdMtCompressJobs,
        zstdMtCompressStream,
        zstdMtSpawnWorker;
import 'package:archive/src/codecs/zstd/zstd_mt_frame_encoder.dart';
import 'package:test/test.dart';

/// Blocks that repeat from far back, the matches a long distance matcher
/// finds. A pool of 64 blocks over 2 MiB puts around 60 in every job, past the
/// 31 that a sequence pool sized by 1000 bytes holds
Uint8List _repeatedBlocks(int size) {
  final random = Random(7);
  final pool = List.generate(
      64,
      (_) =>
          Uint8List.fromList(List.generate(4096, (_) => random.nextInt(256))));
  final out = Uint8List(size);
  for (var at = 0; at < size; at += 4096) {
    out.setRange(at, at + 4096, pool[random.nextInt(pool.length)]);
  }
  return out;
}

Future<Uint8List> _encode(Uint8List src,
    {int level = 6, int workers = 4, int jobSize = 0, int overlapLog = 0}) {
  final done = Completer<Uint8List>();
  final returned = ZstdEncoder(level: level).encodeBytes(src,
      checksum: false,
      multithread: ZstdMultithreadOptions(
        onDone: done.complete,
        onError: done.completeError,
        workers: workers,
        jobSize: jobSize,
        overlapLog: overlapLog,
      ));
  expect(returned, isEmpty);
  return done.future;
}

/// Answers every job with an error. It sends each job index to the second
/// port
void _failingWorker(List<Object> ports) {
  final replies = ports[0] as SendPort;
  final given = ports[1] as SendPort;
  final port = ReceivePort();
  replies.send(port.sendPort);
  port.listen((message) {
    if (message == null) {
      port.close();
      return;
    }
    final index = (message as List)[0] as int;
    given.send(index);
    replies.send([port.sendPort, index, null, 'job failed', '']);
  });
}

void _delayedFirstWorker(List<Object> ports) {
  final replies = ports[0] as SendPort;
  final given = ports[1] as SendPort;
  final port = ReceivePort();
  replies.send(port.sendPort);
  void reply(int index) {
    replies.send([
      port.sendPort,
      index,
      TransferableTypedData.fromList([
        Uint8List.fromList([index])
      ]),
      null,
      null,
    ]);
  }

  port.listen((message) {
    if (message == null) {
      port.close();
      return;
    }
    if (message == true) {
      reply(0);
      return;
    }
    final index = (message as List)[0] as int;
    given.send([index, port.sendPort]);
    if (index != 0) reply(index);
  });
}

void main() {
  // Long runs and a scatter of noise, so the parse has both matches and
  // literals to choose between across a job boundary
  final input = Uint8List(1500000);
  var state = 1;
  for (var i = 0; i < input.length; i++) {
    state = state * 48271 % 2147483647;
    input[i] = i % 3000 < 2400 ? (i >> 4) & 0xff : state & 0xff;
  }

  test('frame decodes back to input', () async {
    final frame = await _encode(input, jobSize: 524288);
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  test('worker count does not change output', () async {
    final one = await _encode(input, workers: 1, jobSize: 524288);
    for (final workers in [2, 3, 8]) {
      expect(await _encode(input, workers: workers, jobSize: 524288), one,
          reason: 'workers $workers');
    }
  });

  test('job size and overlap change output', () async {
    final held = await _encode(input, jobSize: 524288);
    expect(await _encode(input, jobSize: 1048576), isNot(held));
    expect(await _encode(input, jobSize: 524288, overlapLog: 9), isNot(held));
  });

  test('input below job minimum gives single-thread frame', () async {
    final small = Uint8List.sublistView(input, 0, 300000);
    expect(await _encode(small),
        ZstdEncoder(level: 6).encodeBytes(small, checksum: false));
  });

  test('encodeStream moves input position to end', () async {
    final small = Uint8List.sublistView(input, 0, 1024);
    final ordinary = InputMemoryStream(small)..skip(17);
    const ZstdEncoder(level: 1).encodeStream(ordinary, OutputMemoryStream());
    expect(ordinary.isEOS, isTrue);

    final parallel = InputMemoryStream(small)..skip(17);
    final output = OutputMemoryStream();
    final done = Completer<bool>();
    const ZstdEncoder(level: 1).encodeStream(parallel, output,
        multithread: ZstdMultithreadOptions(
          workers: 1,
          onDone: done.complete,
          onError: done.completeError,
        ));
    expect(await done.future, isTrue);
    expect(ZstdDecoder().decodeBytes(output.getBytes(), throwOnError: true),
        Uint8List.sublistView(small, 17));
    expect(parallel.position, ordinary.position);
  });

  test('checksum covers whole input', () async {
    final done = Completer<Uint8List>();
    ZstdEncoder(level: 1).encodeBytes(input,
        multithread: ZstdMultithreadOptions(
            onDone: done.complete, jobSize: 524288, workers: 2));
    final frame = await done.future;
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  // Sizes and CRC32s of the frame this writes with 512 KB jobs, each one
  // checked against `zstd -T4` when it was taken
  const golden = {
    1: [347511, 2857033639],
    2: [338931, 821975185],
    3: [330656, 2728980344],
    4: [331597, 3025348148],
    5: [330535, 824438816],
    6: [307385, 553688082],
    7: [303744, 1404570688],
    8: [303756, 1183189126],
    9: [303756, 1183189126],
    10: [303739, 2920552062],
    11: [303639, 711546979],
    12: [303639, 711546979],
    13: [303620, 3284221855],
    14: [303759, 3336732534],
    15: [303840, 4031621013],
    16: [303038, 338922815],
    17: [303040, 1808676593],
    18: [302871, 1862306182],
    19: [302812, 3661292887],
    20: [302812, 3661292887],
    21: [302834, 645373895],
    22: [302845, 4012362388],
  };
  for (var level = 1; level <= 22; level++) {
    test('level $level output equals reference output', () async {
      final frame = await _encode(input, level: level, jobSize: 524288);
      expect([frame.length, getCrc32(frame)], golden[level]);
    });
  }

  Future<Uint8List> transform(int workers, {int jobSize = 524288}) async {
    final pieces = <List<int>>[];
    for (var at = 0; at < input.length; at += 100000) {
      final end = at + 100000 < input.length ? at + 100000 : input.length;
      pieces.add(Uint8List.sublistView(input, at, end));
    }
    final out = <int>[];
    await for (final piece in Stream.fromIterable(pieces).transform(ZstdCodec(
      level: 6,
      frameChecksum: false,
      multithread:
          ZstdMultithreadOptions.converter(workers: workers, jobSize: jobSize),
    ).encoder)) {
      out.addAll(piece);
    }
    return Uint8List.fromList(out);
  }

  test('transform output decodes back', () async {
    final frame = await transform(4);
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  test('transform sends each job in pieces of at most 64 KiB', () async {
    var largest = 0;
    final out = BytesBuilder(copy: false);
    await for (final piece
        in Stream<List<int>>.fromIterable([input]).transform(const ZstdCodec(
      level: 6,
      frameChecksum: false,
      multithread:
          ZstdMultithreadOptions.converter(workers: 2, jobSize: 524288),
    ).encoder)) {
      if (piece.length > largest) {
        largest = piece.length;
      }
      out.add(piece);
    }
    final frame = out.toBytes();
    expect(largest, lessThanOrEqualTo(1 << 16));
    expect(frame, await transform(2));
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  test('transform output does not depend on worker count', () async {
    final one = await transform(1);
    expect(await transform(4), one);
    expect(await transform(8), one);
  });

  test('level 22 streaming jobs give reference output', () async {
    final source = Uint8List.sublistView(input, 0, 1048577);
    Stream<List<int>> pieces() async* {
      for (var at = 0; at < source.length; at += 131071) {
        final end = at + 131071 < source.length ? at + 131071 : source.length;
        yield Uint8List.sublistView(source, at, end);
      }
    }

    final frame = await pieces()
        .transform(const ZstdCodec(
      level: 22,
      frameChecksum: false,
      multithread: ZstdMultithreadOptions.converter(
          workers: 1, jobSize: 524288, overlapLog: 1),
    ).encoder)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    // ZSTD_compressStream2 enables LDM when the content size is unknown at level 22
    expect([frame.length, getCrc32(frame)], [211267, 4043156817]);
  });

  test('empty stream gives reference frame', () async {
    final frame = await const Stream<List<int>>.empty()
        .transform(const ZstdCodec(
      level: 1,
      frameChecksum: false,
      multithread: ZstdMultithreadOptions.converter(workers: 1),
    ).encoder)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    expect(frame, [0x28, 0xb5, 0x2f, 0xfd, 0x20, 0, 1, 0, 0]);
  });

  test('job size below minimum gives same output as minimum', () async {
    // `ZSTD_CCtxParams_setParameter` raises a job size below
    // ZSTDMT_JOBSIZE_MIN to that minimum, so both of these cut the same jobs.
    // Sizing the long distance matcher by the given number instead left its
    // sequence pool at 31 matches a job, not 16384: end to end at level 22
    // over 66 MiB of repeated blocks the frame was 8948920 bytes against
    // 1149082, and `zstd -22 --ultra -T2 -B1000 --zstd=ovlog=1` writes 1149082
    //
    // The matcher needs a window of 2^27, which an input only reaches at
    // 64 MiB and minutes of work, so paramsSize sets the window here
    const paramsSize = 1 << 27;
    final source = _repeatedBlocks(2 << 20);
    Future<List<Uint8List>> jobs(int jobSize) {
      final geometry = ZstdMtFrameEncoder.geometry(22, paramsSize,
          jobSize: jobSize, overlapLog: 1);
      final starts = <int>[0];
      for (var at = geometry[0]; at < source.length; at += geometry[0]) {
        starts.add(at);
      }
      return zstdMtCompressJobs(source, starts, geometry[1], 22,
          jobSize: jobSize,
          overlapLog: 1,
          workers: 2,
          size: source.length,
          paramsSize: paramsSize);
    }

    expect(await jobs(1000), await jobs(zstdMtJobSizeMin));
  }, testOn: 'vm');

  test('negative level works for any input size', () async {
    for (final size in [zstdMtJobSizeMin, zstdMtJobSizeMin + 1]) {
      final source = Uint8List.sublistView(input, 0, size);
      final frame = await _encode(source, level: -1, workers: 2);
      expect(ZstdDecoder().decodeBytes(frame, throwOnError: true), source,
          reason: '$size bytes');
    }
    // Under the job size minimum the frame is the single threaded one
    final small = Uint8List.sublistView(input, 0, zstdMtJobSizeMin);
    expect(await _encode(small, level: -1, workers: 2),
        ZstdEncoder(level: -1).encodeBytes(small, checksum: false));
  }, testOn: 'vm');

  // The last job of a stream is whatever arrived after the one before it, and a
  // source that fails part way through a job has to end the frame, not hang it
  group('transform whose input ends', () {
    Future<List<int>> encode(Uint8List source, int piece,
        {int workers = 4}) async {
      Stream<List<int>> pieces() async* {
        for (var at = 0; at < source.length; at += piece) {
          final end = at + piece < source.length ? at + piece : source.length;
          yield Uint8List.sublistView(source, at, end);
        }
      }

      return pieces()
          .transform(ZstdCodec(
        level: 6,
        frameChecksum: false,
        multithread:
            ZstdMultithreadOptions.converter(workers: workers, jobSize: 524288),
      ).encoder)
          .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)).timeout(
              const Duration(seconds: 60));
    }

    for (final length in [2 * 524288 + 12345, 2 * 524288, 1000]) {
      final label = length == 2 * 524288
          ? 'on a job boundary'
          : (length < 524288
              ? 'before the first job is full'
              : 'part way into a job');
      test('$label writes one frame for any input pieces', () async {
        final source = Uint8List.sublistView(input, 0, length);
        final whole = await encode(source, source.length);
        expect(
            ZstdDecoder().decodeBytes(whole, verify: true, throwOnError: true),
            source);
        for (final piece in [4099, 524288 + 7]) {
          expect(await encode(source, piece), whole,
              reason: 'pieces of $piece');
        }
        expect(await encode(source, 4099, workers: 1), whole,
            reason: 'one worker');
      });
    }

    for (final at in [1000, 700000, 2 * 524288]) {
      test('source error after $at bytes ends stream with same error',
          () async {
        final source = StreamController<List<int>>();
        final output = source.stream
            .transform(const ZstdCodec(
              level: 6,
              multithread:
                  ZstdMultithreadOptions.converter(workers: 4, jobSize: 524288),
            ).encoder)
            .toList()
            .timeout(const Duration(seconds: 60));
        source.add(Uint8List.sublistView(input, 0, at));
        source.addError(StateError('source failed'));
        await expectLater(output, throwsStateError);
        expect(source.hasListener, isFalse);
        await source.close();
      });
    }

    test('no bytes are sent after source error', () async {
      final source = StreamController<List<int>>();
      final events = <String>[];
      final ended = Completer<void>();
      source.stream
          .transform(const ZstdCodec(
            level: 6,
            multithread:
                ZstdMultithreadOptions.converter(workers: 4, jobSize: 524288),
          ).encoder)
          .listen((_) => events.add('data'),
              onError: (Object _) => events.add('error'),
              onDone: ended.complete);
      source.add(Uint8List.sublistView(input, 0, 1000));
      source.addError(StateError('source failed'));
      await ended.future.timeout(const Duration(seconds: 60));
      await source.close();
      expect(events.sublist(events.indexOf('error')), ['error']);
    });
  });

  test('cancel over silent input releases input', () async {
    // Parked on an input that neither sends nor closes: before the first job
    // is full, and with a job already out on a worker
    for (final start in [0, 1000, 600000]) {
      final source = StreamController<List<int>>();
      final subscription = source.stream
          .transform(const ZstdCodec(
            level: 1,
            multithread:
                ZstdMultithreadOptions.converter(workers: 2, jobSize: 524288),
          ).encoder)
          .listen((_) {});
      if (start > 0) {
        source.add(Uint8List.sublistView(input, 0, start));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await subscription.cancel().timeout(const Duration(seconds: 10));
      expect(source.hasListener, isFalse, reason: 'after $start bytes');
      await source.close();
    }
  }, testOn: 'vm');

  test('failed spawn kills worker already started', () async {
    final exited = ReceivePort();
    final real = zstdMtSpawnWorker;
    addTearDown(() {
      zstdMtSpawnWorker = real;
      exited.close();
    });
    var spawned = 0;
    zstdMtSpawnWorker = (replies, errors) async {
      if (spawned++ > 0) {
        throw StateError('no more isolates');
      }
      final isolate = await real(replies, errors);
      isolate.addOnExitListener(exited.sendPort);
      return isolate;
    };
    final failed = Completer<Object>();
    Stream<List<int>>.value(Uint8List(1000))
        .transform(const ZstdCodec(
          level: 1,
          multithread: ZstdMultithreadOptions.converter(workers: 2),
        ).encoder)
        .listen((_) {}, onError: failed.complete, cancelOnError: true);
    expect(await failed.future.timeout(const Duration(seconds: 10)),
        isA<StateError>());
    await exited.first.timeout(const Duration(seconds: 10));
  }, testOn: 'vm');

  // One worker gets eight jobs. The first job fails and the frame is lost.
  // The pool must not send the worker a second job
  test('failed job stops pool from starting more jobs', () async {
    final real = zstdMtSpawnWorker;
    final given = ReceivePort();
    addTearDown(() {
      zstdMtSpawnWorker = real;
      given.close();
    });
    var jobs = 0;
    given.listen((_) => jobs++);
    zstdMtSpawnWorker = (replies, errors) => Isolate.spawn(
        _failingWorker, [replies, given.sendPort],
        onError: errors, errorsAreFatal: true);
    await expectLater(
        _encode(Uint8List(8 * 524288), level: 1, workers: 1, jobSize: 524288),
        throwsA(isA<ArchiveException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(jobs, 1);
  }, testOn: 'vm');

  test('failed job reaches converter as ArchiveException', () async {
    final real = zstdMtSpawnWorker;
    final given = ReceivePort();
    addTearDown(() {
      zstdMtSpawnWorker = real;
      given.close();
    });
    zstdMtSpawnWorker = (replies, errors) => Isolate.spawn(
        _failingWorker, [replies, given.sendPort],
        onError: errors, errorsAreFatal: true);
    await expectLater(
        Stream<List<int>>.fromIterable(
                [for (var i = 0; i < 8; i++) Uint8List(524288)])
            .transform(const ZstdCodec(
              level: 1,
              multithread:
                  ZstdMultithreadOptions.converter(workers: 1, jobSize: 524288),
            ).encoder)
            .toList(),
        throwsA(isA<ArchiveException>()));
  }, testOn: 'vm');

  for (final path in ['file', 'transform']) {
    test('$path limits completed jobs held while first job waits', () async {
      final real = zstdMtSpawnWorker;
      final given = ReceivePort();
      final first = Completer<SendPort>();
      final allJobs = Completer<void>();
      final jobs = <int>[];
      final parts = <Uint8List>[];
      given.listen((message) {
        final event = message as List;
        final index = event[0] as int;
        jobs.add(index);
        if (index == 0) first.complete(event[1] as SendPort);
        if (jobs.length == 8) allJobs.complete();
      });
      addTearDown(() {
        zstdMtSpawnWorker = real;
        given.close();
      });
      zstdMtSpawnWorker = (replies, errors) => Isolate.spawn(
          _delayedFirstWorker, [replies, given.sendPort],
          onError: errors, errorsAreFatal: true);
      final Future<void> done;
      if (path == 'file') {
        done = zstdMtCompressFileJobs('unused', 0, 8 * 524288,
                List.generate(8, (i) => i * 524288), 0, 1,
                jobSize: 524288, overlapLog: 0, workers: 2, onPart: parts.add)
            .then((_) {});
      } else {
        done = zstdMtCompressStream(
                Stream<List<int>>.fromIterable([
                  for (var i = 0; i < 7; i++) Uint8List(524288),
                  [0],
                ]),
                1,
                jobSize: 524288,
                overlapLog: 0,
                workers: 2)
            .forEach(parts.add);
      }
      final release = await first.future.timeout(const Duration(seconds: 5));
      late List<int> started;
      late int written;
      try {
        await allJobs.future
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        started = List<int>.of(jobs);
        written = parts.length;
      } finally {
        release.send(true);
        await done.timeout(const Duration(seconds: 5));
      }
      expect(written, 0);
      expect(parts, [
        for (var i = 0; i < 8; i++) [i]
      ]);
      // Two workers and the two jobs they may run ahead of the part written
      // next, the `nbJobs = nbWorkers + 2` of `ZSTDMT_createCompressionJob`
      expect(started.length, lessThanOrEqualTo(4),
          reason: 'jobs started before job 0 was released: $started');
    }, testOn: 'vm');
  }

  test('cancel of output cancels input subscription', () async {
    final input = StreamController<List<int>>();
    final firstBody = Completer<void>();
    final output = input.stream.transform(const ZstdCodec(
      level: 1,
      multithread:
          ZstdMultithreadOptions.converter(workers: 1, jobSize: 524288),
    ).encoder);
    var events = 0;
    final subscription = output.listen((_) {
      if (++events == 2) firstBody.complete();
    });
    input.add(Uint8List(524288));
    await firstBody.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    final stillListening = input.hasListener;
    await input.close();
    expect(stillListening, isFalse);
    // A generator suspended in `await for` over a controller never completes
    // its cancel on either web backend, whatever the stream under it does: the
    // same twelve lines with a passthrough generator hang there too
  }, testOn: 'vm');

  test('pause of output stops reading input', () async {
    final inputEnded = Completer<void>();
    final firstBody = Completer<void>();
    Stream<List<int>> source() async* {
      for (var i = 0; i < 8; i++) {
        yield Uint8List(524288);
      }
      inputEnded.complete();
    }

    var events = 0;
    late StreamSubscription<List<int>> subscription;
    subscription = source()
        .transform(const ZstdCodec(
      level: 1,
      multithread:
          ZstdMultithreadOptions.converter(workers: 1, jobSize: 524288),
    ).encoder)
        .listen((_) {
      if (++events == 2) {
        subscription.pause();
        firstBody.complete();
      }
    });
    await firstBody.future.timeout(const Duration(seconds: 10));
    final consumedAll = await inputEnded.future
        .then((_) => true)
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
    await subscription.cancel();
    expect(consumedAll, isFalse);
  });

  test('transform with invalid memoryBudget throws ArgumentError', () async {
    final output = Stream<List<int>>.value([1, 2, 3]).transform(
      const ZstdCodec(
        level: 1,
        multithread:
            ZstdMultithreadOptions.converter(workers: 1, memoryBudget: 0),
      ).encoder,
    );
    await expectLater(output.toList(), throwsArgumentError);
  });

  group('worker pool size from settings', () {
    // The geometry of the streamed frame, which is what the transform runs on
    List<int> geometry(int level) =>
        ZstdMtFrameEncoder.geometry(level, zstdMtSizeUnknown,
            jobSize: 0, overlapLog: 0);

    test('budget below 1 worker still allows 1 worker', () {
      for (final level in [1, 6, 12, 19]) {
        expect(zstdMtWorkerCap(1, level, zstdMtSizeUnknown, geometry(level)), 1,
            reason: 'level $level');
      }
    });

    test('budget allows workers by memory per worker', () {
      const level = 6;
      final cost = zstdMtWorkerCost(level, zstdMtSizeUnknown, geometry(level));
      for (final workers in [1, 3, 7]) {
        expect(
            zstdMtWorkerCap(
                cost * workers, level, zstdMtSizeUnknown, geometry(level)),
            workers);
      }
      expect(zstdMtWorkerCap(0, level, zstdMtSizeUnknown, geometry(level)), 0,
          reason: 'no budget is no bound');
    });

    test('pool size is requested workers limited by budget and cores', () {
      expect(zstdMtPoolSize(4, 16, 0), 4, reason: 'no cap, no change');
      expect(zstdMtPoolSize(4, 16, 1), 1, reason: 'the cap lowers it');
      expect(zstdMtPoolSize(4, 16, 9), 4, reason: 'a cap above it does not');
      expect(zstdMtPoolSize(64, 8, 0), 8, reason: 'no more than the cores');
      expect(zstdMtPoolSize(0, 16, 0), 15,
          reason: 'a core left for the caller');
      expect(zstdMtPoolSize(0, 16, 2), 2);
      expect(zstdMtPoolSize(0, 1, 0), 1, reason: 'never below one');
    });

    test('transform with 1-byte budget gives same output', () async {
      Future<List<int>> run(int budget) async {
        final parts = <int>[];
        await for (final part
            in Stream<List<int>>.value(input).transform(ZstdCodec(
          level: 1,
          frameChecksum: false,
          multithread: ZstdMultithreadOptions.converter(
              workers: 4, memoryBudget: budget, jobSize: 524288),
        ).encoder)) {
          parts.addAll(part);
        }
        return parts;
      }

      expect(await run(1), await run(1 << 30));
    });
  }, testOn: 'vm');

  test('transform reads next chunk only after current one is used', () async {
    Stream<List<int>> source() async* {
      final buffer = Uint8List(1000)..fillRange(0, 1000, 1);
      yield buffer;
      buffer.fillRange(0, 1000, 2);
      yield buffer;
    }

    Future<List<int>> encode(ZstdCodec codec) => source()
        .transform(codec.encoder)
        .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    final expected = [
      ...List<int>.filled(1000, 1),
      ...List<int>.filled(1000, 2)
    ];
    final ordinary = await encode(const ZstdCodec(level: 1));
    expect(
        ZstdDecoder().decodeBytes(ordinary, verify: true, throwOnError: true),
        expected);
    final parallel = await encode(const ZstdCodec(
      level: 1,
      multithread: ZstdMultithreadOptions.converter(workers: 1),
    ));
    expect(
        ZstdDecoder().decodeBytes(parallel, verify: true, throwOnError: true),
        expected);
  });

  test('small job size is raised to reference minimum', () async {
    final src = Uint8List.fromList(
      List<int>.generate(600000, (i) => (i * 13 + (i >> 9)) & 255),
    );
    final minimum = await _encode(src, level: 1, workers: 1, jobSize: 524288);
    final smaller = await _encode(src, level: 1, workers: 1, jobSize: 262144);
    expect(smaller, minimum);
  });

  test('large job size is lowered to reference maximum', () {
    const maximum = 1 << 30;
    for (final level in [1, 6, 12, 19, 22]) {
      final expected = ZstdMtFrameEncoder.geometry(level, zstdMtSizeUnknown,
          jobSize: maximum);
      expect(expected.first, maximum);
      for (final jobSize in [maximum + 1, 2 * maximum - 1]) {
        expect(
            ZstdMtFrameEncoder.geometry(level, zstdMtSizeUnknown,
                jobSize: jobSize),
            expected,
            reason: 'level $level, jobSize $jobSize');
      }
    }
  });

  test('input read error reaches onError', () async {
    final error = Completer<Object>();
    var completed = false;
    expect(
        () => ZstdEncoder().encodeStream(
            _UnreadableInput(), OutputMemoryStream(),
            multithread: ZstdMultithreadOptions<bool>(
                workers: 1,
                onDone: (_) => completed = true,
                onError: (failure, _) => error.complete(failure))),
        returnsNormally);
    expect(await error.future.timeout(const Duration(seconds: 5)),
        isA<FileSystemException>());
    expect(completed, isFalse);
  });

  test('RangeError reaches onError as ArchiveException', () async {
    final error = Completer<Object>();
    ZstdEncoder().encodeStream(
        _BrokenInput(RangeError('bug')), OutputMemoryStream(),
        multithread: ZstdMultithreadOptions<bool>(
            workers: 1,
            onDone: (_) {},
            onError: (failure, _) => error.complete(failure)));
    expect(await error.future.timeout(const Duration(seconds: 5)),
        isA<ArchiveException>());
  });

  test('file output error reaches onError', () async {
    final directory = Directory.systemTemp.createTempSync('zstd-multithread-');
    final file = File('${directory.path}/input')
      ..writeAsBytesSync(Uint8List(600000));
    final input = InputFileStream(file.path);
    final result = Completer<String>();
    runZonedGuarded(() {
      const ZstdEncoder(level: 1).encodeStream(input, _FailingOutput(),
          multithread: ZstdMultithreadOptions(
            workers: 1,
            onDone: (_) => result.complete('onDone'),
            onError: (_, __) => result.complete('onError'),
          ));
    }, (_, __) => result.complete('uncaught zone error'));
    try {
      expect(
          await result.future.timeout(const Duration(seconds: 10)), 'onError');
    } finally {
      input.closeSync();
      directory.deleteSync(recursive: true);
    }
  }, testOn: 'vm');

  test('startChunkedConversion with multithread throws ArgumentError', () {
    expect(
        () =>
            ZstdCodec(multithread: ZstdMultithreadOptions.converter(workers: 2))
                .encoder
                .startChunkedConversion(_Held()),
        throwsArgumentError);
  });

  test('invalid workers, budget or job settings throw ArgumentError', () {
    void call({int workers = 1, int jobSize = 0, int overlapLog = 0}) =>
        ZstdEncoder().encodeBytes(input,
            multithread: ZstdMultithreadOptions(
                onDone: (_) {},
                workers: workers,
                jobSize: jobSize,
                overlapLog: overlapLog));
    expect(() => call(workers: 0), throwsArgumentError);
    expect(() => call(overlapLog: 10), throwsArgumentError);
    expect(() => call(overlapLog: -1), throwsArgumentError);
    expect(() => call(jobSize: -1), throwsArgumentError);
  });

  test('dictionary is used by first job and its id is in frame header',
      () async {
    final dictionary = ZstdDictionary(Uint8List.sublistView(input, 0, 4096));
    final done = Completer<Uint8List>();
    ZstdEncoder(level: 6, dictionary: dictionary).encodeBytes(input,
        checksum: false,
        multithread: ZstdMultithreadOptions(
            onDone: done.complete,
            onError: done.completeError,
            jobSize: 524288,
            workers: 4));
    final frame = await done.future;
    expect(
        ZstdDecoder(dictionary: dictionary)
            .decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  group('onProgress', () {
    final src = _repeatedBlocks(6 << 20);
    const jobSize = 1 << 20;

    void expectProgress(List<int> seen) {
      expect(seen.length, greaterThan(1));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.last, src.length);
    }

    test('encodeBytes reports input of written jobs', () async {
      final seen = <int>[];
      final done = Completer<Uint8List>();
      const ZstdEncoder(level: 3).encodeBytes(src,
          multithread: ZstdMultithreadOptions<Uint8List>(
              onDone: done.complete,
              onError: done.completeError,
              workers: 2,
              jobSize: jobSize,
              onProgress: seen.add));
      expect(ZstdDecoder().decodeBytes(await done.future), src);
      expectProgress(seen);
    });

    test('progress grows inside job as blocks are compressed', () async {
      final seen = <int>[];
      await for (final _ in Stream<List<int>>.fromIterable([src]).transform(
          ZstdEncoderConverter(
              level: 3,
              multithread: ZstdMultithreadOptions.converter(
                  workers: 1, onProgress: seen.add)))) {}
      expect(seen.where((consumed) => consumed < src.length).length,
          greaterThan(2));
      expectProgress(seen);
    });

    test('encodeStream of file reports progress', () async {
      final dir = Directory.systemTemp.createTempSync('zstd-progress');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/src.bin';
      File(path).writeAsBytesSync(src);
      final seen = <int>[];
      final output = OutputMemoryStream();
      final done = Completer<bool>();
      final input = InputFileStream(path);
      const ZstdEncoder(level: 3).encodeStream(input, output,
          multithread: ZstdMultithreadOptions<bool>(
              onDone: done.complete,
              onError: done.completeError,
              workers: 2,
              jobSize: jobSize,
              onProgress: seen.add));
      await done.future;
      await input.close();
      expect(ZstdDecoder().decodeBytes(output.getBytes()), src);
      expectProgress(seen);
    }, testOn: 'vm');

    test('converter reports progress', () async {
      final seen = <int>[];
      final out = BytesBuilder(copy: false);
      await for (final piece in Stream<List<int>>.fromIterable([
        for (var at = 0; at < src.length; at += 1 << 16)
          Uint8List.sublistView(src, at, at + (1 << 16))
      ]).transform(ZstdEncoderConverter(
          level: 3,
          multithread: ZstdMultithreadOptions.converter(
              workers: 2, jobSize: jobSize, onProgress: seen.add)))) {
        out.add(piece);
      }
      expect(ZstdDecoder().decodeBytes(out.toBytes()), src);
      expectProgress(seen);
    });

    test('onProgress error goes to zone and encode continues', () async {
      final errors = <Object>[];
      final converted = Completer<Uint8List>();
      final bytes = Completer<Uint8List>();
      runZonedGuarded(() {
        unawaited(Stream<List<int>>.fromIterable([src])
            .transform(ZstdEncoderConverter(
                level: 3,
                multithread: ZstdMultithreadOptions.converter(
                    workers: 2,
                    jobSize: jobSize,
                    onProgress: (_) => throw StateError('stop'))))
            .fold(BytesBuilder(copy: false), (b, piece) => b..add(piece))
            .then((b) => converted.complete(b.toBytes())));
        const ZstdEncoder(level: 3).encodeBytes(src,
            multithread: ZstdMultithreadOptions<Uint8List>(
                onDone: bytes.complete,
                onError: bytes.completeError,
                workers: 2,
                jobSize: jobSize,
                onProgress: (_) => throw StateError('stop')));
      }, (error, _) => errors.add(error));
      expect(ZstdDecoder().decodeBytes(await converted.future), src);
      expect(ZstdDecoder().decodeBytes(await bytes.future), src);
      expect(errors, isNotEmpty);
      expect(errors, everyElement(isA<StateError>()));
    });
  });
}

class _Held implements Sink<List<int>> {
  @override
  void add(List<int> data) {}
  @override
  void close() {}
}

class _UnreadableInput extends InputMemoryStream {
  _UnreadableInput() : super([1, 2, 3]);

  @override
  Uint8List toUint8List() => throw FileSystemException('input failed');
}

class _BrokenInput extends InputMemoryStream {
  final Object failure;

  _BrokenInput(this.failure) : super([1, 2, 3]);

  @override
  Uint8List toUint8List() => throw failure;
}

class _FailingOutput extends OutputMemoryStream {
  @override
  void writeBytes(List<int> bytes, {int? length}) =>
      throw StateError('output failed');
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// The contract every chunked codec inherits, checked through both of the sinks
// that use it. What a codec does with the bytes is its own business; what it
// does with a caller that feeds it badly is the base's, and is the same for all
// of them.

Future<void> _expectLazySubscription<S, T>(
    StreamTransformer<S, T> transformer) async {
  var listens = 0;
  var cancelled = false;
  final started = Completer<void>();
  final source = StreamController<S>(
    onListen: () {
      listens++;
      started.complete();
    },
    onCancel: () => cancelled = true,
  );
  final transformed = source.stream.transform(transformer);
  StreamSubscription<T>? subscription;
  addTearDown(() async {
    subscription ??= transformed.listen((_) {});
    await subscription!.cancel().timeout(const Duration(seconds: 5));
    expect(cancelled, isTrue);
    await source.close();
  });
  await Future<void>.delayed(Duration.zero);
  expect(listens, 0);
  subscription = transformed.listen((_) {});
  await started.future.timeout(const Duration(seconds: 5));
  expect(listens, 1);
}

Future<void> _expectBroadcastRead<S>(
    Future<Object?> Function(Stream<S> source) read, List<S> events) async {
  final expected = await read(Stream.fromIterable(events));
  final source = StreamController<S>.broadcast();
  final result = read(source.stream)
      .then<Object?>((value) => value, onError: (Object error) => error);
  events.forEach(source.add);
  await source.close();
  expect(await result.timeout(const Duration(seconds: 10)), expected);
}

List<List<int>> _slices(List<int> bytes) => [
      for (var at = 0; at < bytes.length; at += 512)
        bytes.sublist(at, at + 512 < bytes.length ? at + 512 : bytes.length),
    ];

Uint8List _sample(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i * 11) & 0xff;
  }
  return data;
}

void main() {
  group('transformers subscribe to source only on listen', () {
    test('tar decoder', () => _expectLazySubscription(tarCodec.decoder));
    test('tar encoder', () => _expectLazySubscription(tarCodec.encoder));
    test('zip encoder', () => _expectLazySubscription(zipCodec.encoder));
    test(
        'threaded xz decoder',
        () => _expectLazySubscription(const XzCodec(
                multithread: XZMultithreadOptions.converter(workers: 2))
            .decoder));
    test(
        'threaded zstd encoder',
        () => _expectLazySubscription(const ZstdCodec(
                multithread: ZstdMultithreadOptions.converter(workers: 2))
            .encoder));
  });

  group('broadcast source loses no event added right after listen', () {
    List<ArchiveFile> files() => [
          for (var i = 0; i < 3; i++)
            ArchiveFile.bytes('f$i.bin', _sample(3000 + i))
              ..lastModTime = 1700000000,
        ];
    Future<Object?> bytesOf(Stream<List<int>> stream) =>
        stream.expand((piece) => piece).toList();

    test(
        'tar decoder',
        () => _expectBroadcastRead<List<int>>(
            (source) => source
                .transform(tarCodec.decoder)
                .asyncMap((entry) async => [
                      entry.name,
                      await entry.content.expand((piece) => piece).toList()
                    ])
                .toList(),
            _slices(TarEncoder().encodeBytes(Archive()
              ..add(files()[0])
              ..add(files()[1])))));
    test(
        'tar encoder',
        () => _expectBroadcastRead<ArchiveFile>(
            (source) => bytesOf(source.transform(tarCodec.encoder)), files()));
    test(
        'zip encoder',
        () => _expectBroadcastRead<ArchiveFile>(
            (source) => bytesOf(source.transform(zipCodec.encoder)), files()));
    test(
        'threaded xz decoder',
        () => _expectBroadcastRead<List<int>>(
            (source) => bytesOf(source.transform(const XzCodec(
                    multithread: XZMultithreadOptions.converter(workers: 2))
                .decoder)),
            _slices(xzCodec.encode(_sample(3000)))));
    test(
        'threaded zstd encoder',
        () => _expectBroadcastRead<List<int>>(
            (source) => bytesOf(source.transform(const ZstdCodec(
                    multithread: ZstdMultithreadOptions.converter(workers: 2))
                .encoder)),
            _slices(_sample(3000))));
  });

  group('ChunkedSink failures', () {
    // A stream hears a failure once, as it does from gzip and zlib in dart:io.
    // A decoder that fails drops the input after it and never closes, as gzip
    // does. The xz, zstd and bzip2 encoders stay open after a source error, as
    // gzip.encoder does. tar, zip and the threaded codecs close on their first
    // failure
    test('every transformer sends source failure to stream once', () async {
      Stream<T> failing<T>(List<T> items) async* {
        yield* Stream.fromIterable(items);
        yield* Stream<T>.error(StateError('source failed'));
        yield* Stream.fromIterable(items);
      }

      Stream<T> watched<T>(Stream<T> source, Completer<void> fed) =>
          source.transform(
              StreamTransformer<T, T>.fromHandlers(handleDone: (sink) {
            fed.complete();
            sink.close();
          }));

      List<List<int>> pieces(List<int> bytes) => [
            for (var at = 0; at < bytes.length; at += 16)
              bytes.sublist(
                  at, at + 16 < bytes.length ? at + 16 : bytes.length),
          ];

      Stream<List<int>> broken(Codec<List<int>, List<int>> codec) {
        final archive = Uint8List.fromList(codec.encode(_sample(100000)));
        archive[0] ^= 0xff;
        return Stream.fromIterable(pieces(archive));
      }

      final files = [
        for (var i = 0; i < 4; i++) ArchiveFile.bytes('f$i.bin', _sample(3000)),
      ];
      final tar = TarEncoder().encodeBytes(Archive()..addFile(files[0]));
      tar[148] ^= 1;
      final data = pieces(_sample(3000));
      final cases = <String, Stream<Object?> Function(Completer<void>)>{
        'xzCodec.decoder': (fed) =>
            watched(broken(xzCodec), fed).transform(xzCodec.decoder),
        'zstdCodec.decoder': (fed) =>
            watched(broken(zstdCodec), fed).transform(zstdCodec.decoder),
        'bzip2Codec.decoder': (fed) =>
            watched(broken(bzip2Codec), fed).transform(bzip2Codec.decoder),
        'xzCodec.encoder': (fed) =>
            watched(failing(data), fed).transform(xzCodec.encoder),
        'zstdCodec.encoder': (fed) =>
            watched(failing(data), fed).transform(zstdCodec.encoder),
        'bzip2Codec.encoder': (fed) =>
            watched(failing(data), fed).transform(bzip2Codec.encoder),
        'tarCodec.decoder': (fed) =>
            watched(Stream.fromIterable(pieces(tar)), fed)
                .transform(tarCodec.decoder),
        'tarCodec.encoder': (fed) =>
            watched(failing(files), fed).transform(tarCodec.encoder),
        'zipCodec.encoder': (fed) =>
            watched(failing(files), fed).transform(zipCodec.encoder),
        'threaded xz decoder': (fed) => watched(broken(xzCodec), fed).transform(
            const XzCodec(
                    multithread: XZMultithreadOptions.converter(workers: 2))
                .decoder),
        'threaded zstd encoder': (fed) => watched(failing(data), fed).transform(
            const ZstdCodec(
                    multithread: ZstdMultithreadOptions.converter(workers: 2))
                .encoder),
      };
      for (final entry in cases.entries) {
        final errors = <Object>[];
        final fed = Completer<void>();
        final ended = Completer<void>();
        entry
            .value(fed)
            .listen((_) {}, onError: errors.add, onDone: ended.complete);
        await Future.any(
                [ended.future, fed.future.then((_) => pumpEventQueue())])
            .timeout(const Duration(seconds: 10));
        expect(errors, hasLength(1), reason: entry.key);
      }
    });

    test('source error, then truncated archive, gives 2 errors, as utf8 does',
        () async {
      Stream<List<int>> halfThenError(List<int> input) async* {
        yield input.sublist(0, input.length ~/ 2);
        throw StateError('source failed');
      }

      final decoders = <String, (Converter<List<int>, Object>, List<int>)>{
        'utf8.decoder': (utf8.decoder, [0x61, 0xe2, 0x82, 0xac]),
        'xzCodec.decoder': (xzCodec.decoder, xzCodec.encode(_sample(100000))),
        'zstdCodec.decoder': (
          zstdCodec.decoder,
          zstdCodec.encode(_sample(100000))
        ),
        'bzip2Codec.decoder': (
          bzip2Codec.decoder,
          bzip2Codec.encode(_sample(100000))
        ),
      };
      for (final MapEntry(key: name, value: (decoder, input))
          in decoders.entries) {
        final errors = <Object>[];
        final subscription = halfThenError(input)
            .transform(decoder)
            .listen((_) {}, onError: errors.add);
        await pumpEventQueue();
        await subscription.cancel();
        expect(errors, hasLength(2), reason: name);
        expect(errors.first, isA<StateError>(), reason: name);
        expect(errors.last, isA<FormatException>(), reason: name);
      }
    });

    // tar, zip and the threaded codecs have no dart:io counterpart. They end the
    // stream on their first failure
    test('tar, zip and threaded transformers close stream on first failure',
        () async {
      void feedBytes(StreamController<List<int>> source, List<int> bytes) {
        for (var at = 0; at < bytes.length; at += 16) {
          source.add(bytes.sublist(
              at, at + 16 < bytes.length ? at + 16 : bytes.length));
        }
      }

      final files = [
        for (var i = 0; i < 4; i++) ArchiveFile.bytes('f$i.bin', _sample(3000)),
      ];
      void failFiles(StreamController<ArchiveFile> source) {
        files.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final data = [for (var i = 0; i < 4; i++) _sample(3000)];
      void failData(StreamController<List<int>> source) {
        data.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final tar = TarEncoder().encodeBytes(Archive()..addFile(files[0]));
      tar[148] ^= 1;
      final xz = Uint8List.fromList(xzCodec.encode(_sample(100000)))
        ..[0] ^= 0xff;

      await _expectEndAfterFailure<List<int>>(
          'tarCodec.decoder',
          (source) => source.transform(tarCodec.decoder),
          (source) => feedBytes(source, tar),
          closes: true);
      await _expectEndAfterFailure<ArchiveFile>('tarCodec.encoder',
          (source) => source.transform(tarCodec.encoder), failFiles,
          closes: true);
      await _expectEndAfterFailure<ArchiveFile>('zipCodec.encoder',
          (source) => source.transform(zipCodec.encoder), failFiles,
          closes: true);
      await _expectEndAfterFailure<List<int>>(
          'threaded xz decoder',
          (source) => source.transform(const XzCodec(
                  multithread: XZMultithreadOptions.converter(workers: 2))
              .decoder),
          (source) => feedBytes(source, xz),
          closes: true);
      await _expectEndAfterFailure<List<int>>(
          'threaded zstd encoder',
          (source) => source.transform(const ZstdCodec(
                  multithread: ZstdMultithreadOptions.converter(workers: 2))
              .encoder),
          failData,
          closes: true);
    });
  });

  group('errors that are not bad data', () {
    test('source error reaches listener unchanged', () async {
      final failure = RangeError('from the source');
      final bytes = <StreamTransformer<List<int>, List<int>>>[
        xzCodec.decoder,
        const XzCodec(multithread: XZMultithreadOptions.converter(workers: 2))
            .decoder,
        xzCodec.encoder,
        zstdCodec.decoder,
        zstdCodec.encoder,
        const ZstdCodec(
                multithread: ZstdMultithreadOptions.converter(workers: 2))
            .encoder,
        bzip2Codec.decoder,
        bzip2Codec.encoder,
      ];
      for (final transformer in bytes) {
        await expectLater(
            Stream<List<int>>.error(failure).transform(transformer).toList(),
            throwsA(same(failure)));
      }
      await expectLater(
          Stream<List<int>>.error(failure).transform(tarCodec.decoder).toList(),
          throwsA(same(failure)));
      for (final encoder in [tarCodec.encoder, zipCodec.encoder]) {
        await expectLater(
            Stream<ArchiveFile>.error(failure).transform(encoder).toList(),
            throwsA(same(failure)));
      }
    });
  });

  test('ChunkedSink keeps held bytes in place while input fits after them', () {
    final sink = _HeaderThenBody(_Held());
    for (final size in [4, 20, 20, 20]) {
      sink.add(Uint8List(size));
    }
    expect(sink.offsets, [8, 8, 8]);
  });

  test('ChunkedSink moves held bytes to front once more was read than is held',
      () {
    final sink = _HeaderThenBody(_Held());
    for (final size in [4, 6, 4]) {
      sink.add(Uint8List(size));
    }
    expect(sink.offsets, [8, 0]);
  });

  test('bound converter decodes no more units while listener is paused',
      () async {
    final converter = _UnitsConverter();
    final source = StreamController<List<int>>();
    final done = Completer<void>();
    var received = 0;
    late StreamSubscription<List<int>> subscription;
    subscription = source.stream.transform(converter).listen((_) {
      if (++received == 1) {
        subscription.pause();
      }
    }, onDone: done.complete);
    source.add(Uint8List(100));
    await Future<void>.delayed(Duration.zero);
    expect(converter.units, 1);
    subscription.resume();
    await source.close();
    await done.future;
    expect(received, 100);
  });

  test('zstd stream paused on every piece gives whole output', () async {
    final data = Uint8List(1 << 20);
    final done = Completer<void>();
    var received = 0;
    late StreamSubscription<List<int>> subscription;
    subscription = Stream.value(zstdCodec.encode(data))
        .transform(zstdCodec.decoder)
        .listen((piece) {
      subscription.pause();
      Timer(Duration.zero, subscription.resume);
      received += piece.length;
    }, onError: done.completeError, onDone: done.complete);
    await done.future;
    expect(received, data.length);
  });

  test('ChunkedSink moves fewer held bytes than it receives', () {
    final sink = _KeepsTail(_Held(), 40000);
    for (var i = 0; i < 100; i++) {
      sink.add(Uint8List(4096));
    }
    expect(sink.moves * 40000, lessThanOrEqualTo(100 * 4096));
  });

  group('SinkOutputStream', () {
    test('writeStream restores input position when read fails', () {
      final failure = StateError('input failed');
      final input = _FailingInput(_sample(131073), failure)..position = 17;
      final output = SinkOutputStream(_Held());

      expect(() => output.writeStream(input), throwsA(same(failure)));
      expect(input.position, 17);
    });

    test('sink receives copies, not views of internal buffer', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      final buffer = Uint8List.fromList([1, 2, 3, 4]);
      out.writeRange(buffer, 0, 4);
      out.flush();
      buffer.fillRange(0, 4, 9);
      expect(held.bytes, [1, 2, 3, 4]);
      expect(out.written, 4);
    });

    test('bytes written while divert is set go to divert, not to sink', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      final buffer = OutputMemoryStream();
      out
        ..divert = buffer
        ..writeBytes([1, 2, 3])
        ..divert = null
        ..writeBytes([4, 5])
        ..flush();
      expect(buffer.getBytes(), [1, 2, 3]);
      expect(held.bytes, [4, 5]);
      expect(out.written, 5);
    });

    test('watch callback sees every written byte', () {
      final held = _Held();
      final seen = <int>[];
      SinkOutputStream(held)
        ..watch = ((piece) => seen.addAll(piece))
        ..writeBytes([7, 8])
        ..writeByte(9)
        ..flush();
      expect(seen, [7, 8, 9]);
      expect(held.bytes, [7, 8, 9]);
    });

    test('reset clears written count and keeps sink output', () {
      final held = _Held();
      final out = SinkOutputStream(held)
        ..writeBytes([1, 2, 3])
        ..flush();
      expect(out.written, 3);
      out.reset();
      expect(out.written, 0);
      expect(held.bytes, [1, 2, 3]);
    });

    // Measured on this SDK: closing the sink of
    // `zlib.encoder.startChunkedConversion` sends the last bytes and closes
    // that sink, and `OutputFileStream` flushes before it closes its file
    test('close flushes queued bytes and closes sink', () async {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      await out.close();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
    });

    test('closeSync flushes queued bytes and closes sink', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out.closeSync();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
    });

    test('second close does nothing, as dart:io does', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out
        ..closeSync()
        ..closeSync();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
    });

    test('clear discards queued bytes', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out.clear();
      expect(out.length, 0);
      out.flush();
      expect(held.bytes, isEmpty,
          reason: 'cleared bytes must not reach the sink later');
    });
  });

  // Measured on this SDK: gzip.decoder and zlib.decoder throw a
  // FormatException out of add on a corrupt stream and leave the sink they
  // were given open, and a close afterwards does not close it either
  group('failed parse leaves output open, as dart:io does', () {
    final source = Uint8List.fromList(List.filled(4096, 65));
    final truncated = <String, Uint8List>{
      'xz': _cut(xzCodec.encoder.convert(source), 20),
      'bzip2': _cut(bzip2Codec.encoder.convert(source), 5),
      'zstd': _cut(zstdCodec.encoder.convert(source), 5),
    };
    final starts = <String, ByteConversionSink Function(Sink<List<int>>)>{
      'xz': xzCodec.decoder.startChunkedConversion,
      'bzip2': bzip2Codec.decoder.startChunkedConversion,
      'zstd': zstdCodec.decoder.startChunkedConversion,
    };

    for (final name in truncated.keys) {
      test(name, () {
        final held = _Watched();
        final sink = starts[name]!(held);
        expect(() {
          sink.add(truncated[name]!);
          sink.close();
        }, throwsA(isA<ArchiveException>()));
        expect(held.closed, isFalse);
        // The failure is remembered, so nothing closes it later on either
        expect(sink.close, returnsNormally);
        expect(held.closed, isFalse);
      });
    }
  });
}

/// Feeds a source that never closes, so only the transformer can end the
/// stream. We expect one error, then a stream that ended or stayed open
Future<void> _expectEndAfterFailure<T>(
    String reason,
    Stream<Object?> Function(Stream<T> source) transform,
    void Function(StreamController<T> source) feed,
    {required bool closes}) async {
  final source = StreamController<T>();
  final errors = <Object>[];
  final failed = Completer<void>();
  final ended = Completer<void>();
  final subscription =
      transform(source.stream).listen((_) {}, onError: (Object error) {
    errors.add(error);
    if (!failed.isCompleted) {
      failed.complete();
    }
  }, onDone: ended.complete);
  feed(source);
  await failed.future.timeout(const Duration(seconds: 10));
  if (closes) {
    await ended.future.timeout(const Duration(seconds: 10));
  } else {
    // A stream that ends would have ended by now
    await pumpEventQueue();
    expect(ended.isCompleted, isFalse, reason: reason);
  }
  await subscription.cancel();
  expect(errors, hasLength(1), reason: reason);
}

Uint8List _cut(List<int> bytes, int off) =>
    Uint8List.fromList(bytes.sublist(0, bytes.length - off));

class _Watched implements Sink<List<int>> {
  var closed = false;

  @override
  void add(List<int> data) {}

  @override
  void close() => closed = true;
}

class _HeaderThenBody extends ChunkedSink {
  final offsets = <int>[];
  var _header = false;

  _HeaderThenBody(super.output);

  @override
  void step() {
    if (!_header) {
      if (available < 8) {
        return;
      }
      skip(8);
      _header = true;
    }
    if (available > 0) {
      offsets.add(view(available).offsetInBytes);
    }
  }

  @override
  void finish() {}
}

class _UnitsConverter extends ChunkedConverter {
  var units = 0;

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _ByteUnits(sink, this);
}

class _ByteUnits extends ChunkedSink {
  final _UnitsConverter _converter;

  _ByteUnits(super.output, this._converter);

  @override
  void step() {
    while (available > 0) {
      skip(1);
      _converter.units++;
      output.add([0]);
      if (unitAtATime) {
        return;
      }
    }
  }

  @override
  void finish() {}
}

class _KeepsTail extends ChunkedSink {
  final int tail;
  var moves = 0;
  var _offset = 0;

  _KeepsTail(super.output, this.tail);

  @override
  void step() {
    if (available <= tail) {
      return;
    }
    final offset = view(available).offsetInBytes;
    if (offset < _offset) {
      moves++;
    }
    final read = available - tail;
    skip(read);
    _offset = offset + read;
  }

  @override
  void finish() {}
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var length = 0;
  var closes = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    length += data.length;
  }

  @override
  void close() {
    closes++;
  }

  Uint8List get bytes {
    final out = Uint8List(length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

class _FailingInput extends InputMemoryStream {
  final Object failure;

  _FailingInput(super.bytes, this.failure);

  @override
  int readInto(Uint8List into, int at, int count) {
    super.readInto(into, at, count);
    throw failure;
  }
}

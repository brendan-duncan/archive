@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/decode_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _archive(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

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
  final sinks = <String, ChunkedSink Function(Sink<List<int>>)>{
    'decoder': (sink) => XzChunkedDecoder(sink),
    'encoder': (sink) => XzChunkedEncoder(sink),
  };
  final feed = <String, Uint8List>{
    'decoder': _archive('hello.xz'),
    'encoder': _sample(500),
  };

  sinks.forEach((name, make) {
    group('ChunkedSink contract, $name', () {
      test('add after close throws StateError', () {
        final sink = make(_Held())
          ..add(feed[name]!)
          ..close();
        expect(() => sink.add(feed[name]!), throwsStateError);
      });

      test('second close does not throw', () {
        final sink = make(_Held())..add(feed[name]!);
        sink.close();
        expect(sink.close, returnsNormally);
      });

      test('output closes once, on input close', () {
        final held = _Held();
        final sink = make(held);
        sink.add(feed[name]!);
        expect(held.closes, 0);
        sink.close();
        expect(held.closes, 1);
      });

      test('addSlice with isLast closes sink and output', () {
        final held = _Held();
        final source = feed[name]!;
        final sink = make(held);
        for (var at = 0; at < source.length; at += 7) {
          final end = at + 7 < source.length ? at + 7 : source.length;
          sink.addSlice(source, at, end, end == source.length);
        }
        expect(held.closes, 1);
        expect(() => sink.add(source), throwsStateError);
      });

      test('addSlice outside buffer throws RangeError', () {
        final sink = make(_Held());
        expect(() => sink.addSlice(feed[name]!, 2, 1, false),
            throwsA(isA<RangeError>()));
        expect(
            () => sink.addSlice(feed[name]!, 0, feed[name]!.length + 1, false),
            throwsA(isA<RangeError>()));
      });

      test('plain List<int> input works like Uint8List', () {
        final held = _Held();
        final sink = make(held);
        // ignore: prefer_typed_lists
        sink.add(<int>[...feed[name]!]);
        sink.close();
        expect(held.length, greaterThan(0));
      });

      test('empty pieces do not change output', () {
        final held = _Held();
        final sink = make(held)
          ..add(const <int>[])
          ..add(feed[name]!)
          ..add(Uint8List(0));
        sink.close();
        expect(held.length, greaterThan(0));
      });

      test('input buffer may be reused right after add returns', () {
        final held = _Held();
        final source = feed[name]!;
        final buffer = Uint8List(source.length);
        final sink = make(held);
        for (var at = 0; at < source.length; at += 5) {
          final end = at + 5 < source.length ? at + 5 : source.length;
          buffer.setRange(0, end - at, source, at);
          sink.addSlice(buffer, 0, end - at, false);
          // What the sink kept must not be a view of this
          buffer.fillRange(0, buffer.length, 0xcd);
        }
        sink.close();
        expect(held.length, greaterThan(0));
      });
    });
  });

  group('ChunkedSink failures', () {
    test('every add and close after failure throws first ArchiveException', () {
      final held = _Held();
      final sink = XzChunkedDecoder(held);
      expect(() => sink.add(Uint8List(64)), throwsA(isA<ArchiveException>()));
      expect(() => sink.add(_archive('hello.xz')),
          throwsA(isA<ArchiveException>()));
      expect(sink.close, throwsA(isA<ArchiveException>()));
      // A failed conversion hands nothing over and closes nothing
      expect(held.length, 0);
      expect(held.closes, 0);
    });

    test('fused decoder sends failure to stream once, as gzip does', () async {
      final codecs = <String, Codec<List<int>, List<int>>>{
        'gzip': gzip,
        'xz': xzCodec,
        'zstd': zstdCodec,
        'bzip2': bzip2Codec,
      };
      for (final MapEntry(key: name, value: codec) in codecs.entries) {
        final archive = Uint8List.fromList(codec.encode(_sample(3000)));
        archive[0] ^= 0xff;
        final errors = <Object>[];
        final subscription = Stream.fromIterable(_slices(archive))
            .transform(codec.decoder.fuse(base64.encoder))
            .listen((_) {}, onError: errors.add);
        await pumpEventQueue();
        await subscription.cancel();
        expect(errors, hasLength(1), reason: name);
      }
    });

    // We behave like gzip.decoder in dart:io. After a failure a decoder drops
    // the rest of the input and never closes the stream. The listener ends it.
    // await for, pipe and toList cancel at the first error on their own. A
    // listen that waits for onDone has to cancel in onError. gzip.decoder is
    // checked here too, so a change on the dart:io side shows up as well
    test('failed decoder stream stays open, as gzip.decoder does', () async {
      Future<void> expectOpen(String reason,
          Converter<List<int>, List<int>> decoder, List<int> bytes) async {
        final errors = <Object>[];
        var closed = false;
        final failed = Completer<void>();
        final subscription = Stream<List<int>>.fromIterable([bytes])
            .transform(decoder)
            .listen((_) {},
                onError: (Object error) {
                  errors.add(error);
                  if (!failed.isCompleted) {
                    failed.complete();
                  }
                },
                onDone: () => closed = true);
        await failed.future.timeout(const Duration(seconds: 10));
        // The source has closed by now, so a stream that ends would have
        await pumpEventQueue();
        await subscription.cancel();
        expect(errors, hasLength(1), reason: reason);
        expect(errors.single, isA<FormatException>(), reason: reason);
        expect(closed, isFalse, reason: reason);
      }

      final gz = Uint8List.fromList(gzip.encode(_sample(100000)))..[0] ^= 0xff;
      await expectOpen('gzip.decoder, broken header', gzip.decoder, gz);

      final codecs = <String, Codec<List<int>, List<int>>>{
        'xz': xzCodec,
        'zstd': zstdCodec,
        'bzip2': bzip2Codec,
      };
      for (final codec in codecs.entries) {
        final archive = Uint8List.fromList(codec.value.encode(_sample(100000)));
        // A broken header fails in add. A cut archive fails in close
        final broken = Uint8List.fromList(archive)..[0] ^= 0xff;
        final cut = archive.sublist(0, archive.length - 5);
        await expectOpen(
            '${codec.key}, broken header', codec.value.decoder, broken);
        await expectOpen('${codec.key}, cut', codec.value.decoder, cut);
      }
    });

    // Encoders follow gzip.encoder in dart:io. An error from the source reaches
    // the stream once, and the stream stays open
    test('failed encoder stream stays open, as gzip.encoder does', () async {
      final data = [for (var i = 0; i < 4; i++) _sample(3000)];
      void failSource(StreamController<List<int>> source) {
        data.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final encoders = <String, Converter<List<int>, List<int>>>{
        'gzip.encoder': gzip.encoder,
        'xzCodec.encoder': xzCodec.encoder,
        'zstdCodec.encoder': zstdCodec.encoder,
        'bzip2Codec.encoder': bzip2Codec.encoder,
      };
      for (final encoder in encoders.entries) {
        await _expectEndAfterFailure<List<int>>(encoder.key,
            (source) => source.transform(encoder.value), failSource,
            closes: false);
      }
    });

    test('any error codec throws on bad data becomes ArchiveException', () {
      final src = Uint8List.fromList(_archive('x86.xz'));
      src[src.length ~/ 2] ^= 0xff;
      expect(
          () => XzChunkedDecoder(_Held())
            ..add(src)
            ..close(),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('errors that are not bad data', () {
    test('exception from output sink is rethrown unchanged', () {
      final data = _sample(300000);
      const failure = FileSystemException('No space left on device');
      final cases = <(ChunkedSink Function(Sink<List<int>>), List<int>)>[
        ((sink) => XzChunkedDecoder(sink), XZEncoder().encodeBytes(data)),
        ((sink) => ZstdChunkedDecoder(sink), ZstdEncoder().encodeBytes(data)),
        ((sink) => BZip2ChunkedDecoder(sink), BZip2Encoder().encodeBytes(data)),
        ((sink) => XzChunkedEncoder(sink), data),
        ((sink) => ZstdChunkedEncoder(sink), data),
        ((sink) => BZip2ChunkedEncoder(sink), data),
      ];
      for (final (make, input) in cases) {
        expect(
            () => make(_FailingSink(failure))
              ..add(input)
              ..close(),
            throwsA(same(failure)));
      }
    });

    test(
        'error inside stream converter becomes ArchiveException, foreign exception stays',
        () async {
      Stream<int> broken(Stream<int> source) async* {
        await for (final value in source) {
          yield value;
        }
        throw RangeError('inside');
      }

      await expectLater(archiveStreamErrors(Stream.value(1), broken).toList(),
          throwsA(isA<ArchiveException>()));
      const failure = FileSystemException('inside');
      Stream<int> foreign(Stream<int> source) async* {
        await for (final value in source) {
          yield value;
        }
        throw failure;
      }

      await expectLater(archiveStreamErrors(Stream.value(1), foreign).toList(),
          throwsA(same(failure)));
    });
  });

  group('ChunkedConverter', () {
    test('convert output equals chunked sink output', () {
      final source = _archive('cat.jpg.xz');
      final held = _Held();
      XzChunkedDecoder(held)
        ..add(source)
        ..close();
      expect(xzCodec.decode(source), held.bytes);
    });

    test('plain Sink output works like ByteConversionSink', () {
      final plain = _Held();
      final sink = xzCodec.decoder.startChunkedConversion(plain);
      expect(sink, isA<ByteConversionSink>());
      sink
        ..add(_archive('hello.xz'))
        ..close();
      expect(plain.length, 6);
    });

    test('paused listener keeps 16 KB of zstd from decoding 512 MB', () async {
      final frame = BytesBuilder()..add([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x38]);
      for (var i = 0; i < 4096; i++) {
        final header = (131072 << 3) | 2 | (i == 4095 ? 1 : 0);
        frame.add([header & 0xff, header >> 8 & 0xff, header >> 16, 0x61]);
      }
      final before = ProcessInfo.currentRss;
      late StreamSubscription<List<int>> subscription;
      subscription = Stream<List<int>>.value(frame.takeBytes())
          .transform(zstdCodec.decoder)
          .listen((_) => subscription.pause());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ProcessInfo.currentRss - before, lessThan(128 << 20));
      await subscription.cancel();
    });
  });

  group('SinkOutputStream', () {
    for (final kind in ['memory', 'file']) {
      for (final failureAt in ['sink', 'watch']) {
        test(
            'writeStream restores $kind subset position after $failureAt failure',
            () {
          final data = _sample(131120);
          late InputStream input;
          if (kind == 'memory') {
            final outer = InputMemoryStream(data, offset: 11, length: 131100);
            input = InputMemoryStream(outer.toUint8List(),
                offset: 7, length: 131073);
          } else {
            final dir = Directory.systemTemp.createTempSync('archive_sink_');
            addTearDown(() => dir.deleteSync(recursive: true));
            final file = File(p.join(dir.path, 'input'))
              ..writeAsBytesSync(data);
            final source = InputFileStream(file.path, bufferSize: 17);
            addTearDown(source.closeSync);
            final outer = InputFileStream.fromFileStream(source,
                position: 11, length: 131100);
            input = InputFileStream.fromFileStream(outer,
                position: 7, length: 131073);
          }
          input.position = 17;
          final failure = StateError('output failed');
          final output = SinkOutputStream(
              failureAt == 'sink' ? _FailingSink(failure) : _Held());
          if (failureAt == 'watch') {
            output.watch = (_) => throw failure;
          }

          expect(() => output.writeStream(input), throwsA(same(failure)));
          expect(input.position, 17);
          expect(input.readByte(), data[35]);
        });
      }
    }
  });
}

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

class _FailingSink implements Sink<List<int>> {
  final Object failure;

  _FailingSink(this.failure);

  @override
  void add(List<int> data) => throw failure;

  @override
  void close() {}
}

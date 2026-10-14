import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// What every knob does at its zero, where the reference has an opinion about
// the value and where the value is refused instead

Uint8List _payload(int length) => Uint8List.fromList(
    List.generate(length, (i) => (i * 31 + (i >> 6) * 7) & 0xff));

Uint8List _chunked(List<int> source, ZstdCodec codec, {int piece = 997}) {
  final out = BytesBuilder();
  final sink = codec.encoder.startChunkedConversion(
      ByteConversionSink.withCallback((bytes) => out.add(bytes)));
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    sink.add(source.sublist(at, end));
  }
  sink.close();
  return out.toBytes();
}

void main() {
  group('zstd level limits', () {
    final source = _payload(200000);

    test('level 0 means reference default 3, not lowest level', () {
      // Data the two levels part on, since most inputs give the same bytes
      final parting = File('test/_data/cat.jpg').readAsBytesSync();
      for (final data in [source, parting]) {
        expect(ZstdEncoder(level: 0).encodeBytes(data),
            ZstdEncoder(level: 3).encodeBytes(data));
      }
      expect(ZstdEncoder(level: 0).encodeBytes(parting),
          isNot(ZstdEncoder(level: 1).encodeBytes(parting)));
    }, testOn: 'vm');

    test('level above 22 is clamped to 22', () {
      final top = ZstdEncoder(level: 22).encodeBytes(source);
      expect(ZstdEncoder(level: 23).encodeBytes(source), top);
      expect(ZstdEncoder(level: 1000).encodeBytes(source), top);
    });

    test('negative level is the fast parse on every path, not level 1', () {
      final fast = ZstdEncoder(level: -1).encodeBytes(source);
      expect(ZstdEncoder(level: -5).encodeBytes(source),
          isNot(ZstdEncoder(level: 1).encodeBytes(source)));
      expect(ZstdEncoder().encodeBytes(source, level: -1), fast);
      final streamed = OutputMemoryStream();
      ZstdEncoder()
          .encodeStream(InputMemoryStream(source), streamed, level: -1);
      expect(streamed.getBytes(), fast);
      for (final frame in [
        ZstdEncoder().encodeBytes(source, level: -3),
        _chunked(source, const ZstdCodec(level: -1)),
      ]) {
        expect(ZstdDecoder().decodeBytes(frame, throwOnError: true), source);
      }
    });

    test('output of every level decodes back', () {
      for (var level = 0; level <= 22; level++) {
        final frame = ZstdEncoder(level: level).encodeBytes(source);
        expect(
            ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            source,
            reason: 'level $level');
      }
    });
  });

  group('zstd with empty input', () {
    test('empty input writes frame that decodes to empty', () {
      for (var level = 0; level <= 22; level++) {
        final frame = ZstdEncoder(level: level).encodeBytes(Uint8List(0));
        expect(frame, isNotEmpty, reason: 'level $level');
        expect(ZstdDecoder().uncompressedSize(frame), 0,
            reason: 'level $level');
        expect(
            ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            isEmpty,
            reason: 'level $level');
      }
    });

    test('empty stream output equals empty buffer output', () {
      final output = OutputMemoryStream();
      ZstdEncoder().encodeStream(InputMemoryStream(Uint8List(0)), output);
      expect(output.getBytes(), ZstdEncoder().encodeBytes(Uint8List(0)));
    });

    test('no chunk and 1 empty chunk give same frame', () {
      const codec = ZstdCodec();
      final none = _chunked(<int>[], codec);
      expect(_chunked(<int>[], codec, piece: 1), none);
      expect(ZstdDecoder().decodeBytes(none, verify: true, throwOnError: true),
          isEmpty);
    });

    test('empty chunks between data do not change output', () {
      final source = _payload(5000);
      const codec = ZstdCodec();
      final out = BytesBuilder();
      final sink = codec.encoder.startChunkedConversion(
          ByteConversionSink.withCallback((bytes) => out.add(bytes)));
      sink.add(const <int>[]);
      for (var at = 0; at < source.length; at += 500) {
        sink.add(const <int>[]);
        sink.add(source.sublist(at, at + 500));
      }
      sink.add(const <int>[]);
      sink.close();
      expect(out.toBytes(), _chunked(source, codec, piece: 500));
    });

    test('empty dictionary gives same output as none', () {
      final source = _payload(4000);
      final empty = ZstdDictionary(Uint8List(0));
      expect(empty.id, 0);
      final frame = ZstdEncoder.withDictionary(empty).encodeBytes(source);
      expect(frame, ZstdEncoder().encodeBytes(source));
      expect(
          ZstdDecoder.withDictionary(empty)
              .decodeBytes(frame, verify: true, throwOnError: true),
          source);
    });

    test('empty archive throws', () {
      expect(() => ZstdDecoder().decodeBytes(Uint8List(0), throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(Uint8List(0)), OutputMemoryStream(),
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(ZstdDecoder().decodeBytes(Uint8List(0)), isEmpty);
    });
  });

  group('zstd invalid settings', () {
    test('window limit below smallest window throws', () {
      for (final limit in [0, 1, 1023]) {
        expect(() => ZstdDecoder(maxWindowSize: limit),
            throwsA(isA<ArgumentError>()),
            reason: 'limit $limit');
      }
      expect(ZstdDecoder(maxWindowSize: 1024), isA<ZstdDecoder>());
    });

    // The converter is const and cannot check the limit. The sink checks it
    // when the conversion starts
    test('window limit below smallest window throws on converter', () {
      ByteConversionSink start(int limit) =>
          ZstdDecoderConverter(maxWindowSize: limit)
              .startChunkedConversion(ByteConversionSink.withCallback((_) {}));
      for (final limit in [0, 1, 1023]) {
        expect(() => start(limit), throwsA(isA<ArgumentError>()),
            reason: 'limit $limit');
      }
      expect(start(1024), isA<ByteConversionSink>());
    });

    test('worker count or budget of 0 throws', () {
      final source = _payload(1 << 20);
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, workers: 0)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, memoryBudget: 0)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, jobSize: -1)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, overlapLog: -1)),
          throwsA(isA<ArgumentError>()));
    });

    test('job size and overlap of 0 mean defaults, no error', () {
      final source = _payload(1 << 20);
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, jobSize: 0, overlapLog: 0)),
          returnsNormally);
    });
  });
}

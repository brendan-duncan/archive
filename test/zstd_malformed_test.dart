import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// A malformed archive has three ways into the decoder and they have to agree:
// either all three refuse it, or all three write the same bytes. The one shot
// path holds the whole frame, the pull path walks it a block at a time and the
// push path is fed in pieces, so a check that lives in only one of them shows
// up here as a disagreement rather than as silence.

/// What one path made of the input: the bytes, or the failure
class _Outcome {
  final Uint8List? bytes;
  final Object? error;
  _Outcome.ok(this.bytes) : error = null;
  _Outcome.failed(this.error) : bytes = null;

  bool get refused => error != null;

  @override
  String toString() => refused ? 'refused' : '${bytes!.length} bytes';
}

_Outcome _whole(Uint8List src) {
  try {
    return _Outcome.ok(
        ZstdDecoder().decodeBytes(src, verify: true, throwOnError: true));
  } catch (error) {
    return _Outcome.failed(error);
  }
}

_Outcome _pull(Uint8List src) {
  try {
    final output = OutputMemoryStream();
    ZstdDecoder().decodeStream(InputMemoryStream(src), output,
        verify: true, throwOnError: true);
    return _Outcome.ok(output.getBytes());
  } catch (error) {
    return _Outcome.failed(error);
  }
}

_Outcome _push(Uint8List src, int piece) {
  try {
    final out = BytesBuilder();
    final sink = const ZstdCodec().decoder.startChunkedConversion(
        ByteConversionSink.withCallback((bytes) => out.add(bytes)));
    for (var at = 0; at < src.length; at += piece) {
      final end = at + piece < src.length ? at + piece : src.length;
      sink.add(Uint8List.sublistView(src, at, end));
    }
    sink.close();
    return _Outcome.ok(out.toBytes());
  } catch (error) {
    return _Outcome.failed(error);
  }
}

/// Runs [src] through all three paths and returns what they agreed on
_Outcome _agreed(Uint8List src, String what) {
  final whole = _whole(src);
  final pull = _pull(src);
  final pushes = [
    for (final piece in [1, 7, 1 << 16]) _push(src, piece)
  ];
  for (final other in [pull, ...pushes]) {
    expect(other.refused, whole.refused,
        reason: '$what: one shot says $whole, another path says $other');
    if (!whole.refused) {
      expect(other.bytes, whole.bytes, reason: '$what: paths differ');
    }
  }
  return whole;
}

void _refuse(Uint8List src, String what) {
  expect(_agreed(src, what).refused, isTrue, reason: '$what was accepted');
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// A frame with everything a decoder has to walk: a Huffman tree, sequences,
/// several blocks and a checksum
final _source = Uint8List.fromList(List.generate(80000, (i) {
  final word = 'the quick brown fox jumps over the lazy dog '.codeUnits;
  return i % 97 == 0 ? (i * 31) & 0xff : word[i % word.length];
}));
final _frame = ZstdEncoder(level: 9).encodeBytes(_source);
final _plain = ZstdEncoder(level: 1).encodeBytes(_source, checksum: false);

/// Where the first block header starts, which is past the frame header
int _firstBlock(Uint8List frame) {
  final descriptor = frame[4];
  const fcs = [0, 2, 4, 8];
  const dict = [0, 1, 2, 4];
  final single = (descriptor >> 5) & 1 != 0;
  final size = (descriptor >> 6) == 0 ? (single ? 1 : 0) : fcs[descriptor >> 6];
  return 5 + (single ? 0 : 1) + dict[descriptor & 3] + size;
}

void main() {
  test('undamaged fixtures decode', () {
    expect(_agreed(_frame, 'the frame').bytes, _source);
    expect(_agreed(_plain, 'the frame without a checksum').bytes, _source);
  });

  test('empty single-segment frame accepts zero-length RLE block', () {
    final frame =
        _bytes([0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x00, 0x03, 0x00, 0x00, 0x00]);
    expect(_agreed(frame, 'zero-length RLE block').bytes, isEmpty);
  });

  group('zstd refuses truncated or padded frame', () {
    test('truncated at every length', () {
      for (var cut = 0; cut < _frame.length; cut++) {
        _refuse(Uint8List.sublistView(_frame, 0, cut), 'cut to $cut');
      }
    });

    test('truncated at every length without checksum', () {
      for (var cut = 0; cut < _plain.length; cut++) {
        _refuse(Uint8List.sublistView(_plain, 0, cut), 'plain cut to $cut');
      }
    });

    test('frame followed by extra bytes throws', () {
      for (final tail in [
        [0],
        [40, 181],
        [40, 181, 47, 253],
        [1, 2, 3, 4, 5, 6, 7, 8],
      ]) {
        _refuse(_bytes([..._frame, ...tail]), 'tail of ${tail.length}');
      }
    });
  });

  group('zstd damaged frame throws or decodes original bytes', () {
    test('every header byte changed', () {
      final header = _firstBlock(_frame) + 3;
      for (var at = 0; at < header; at++) {
        for (final mask in [0x01, 0x40, 0xff]) {
          final bytes = Uint8List.fromList(_frame);
          bytes[at] ^= mask;
          final outcome = _agreed(bytes, 'byte $at with $mask');
          if (!outcome.refused) {
            expect(outcome.bytes, _source,
                reason: 'byte $at with $mask changed the output silently');
          }
        }
      }
    });

    test('1000 random single-byte changes', () {
      final random = Random(20260913);
      for (var i = 0; i < 1000; i++) {
        final bytes = Uint8List.fromList(_frame);
        final at = random.nextInt(bytes.length);
        bytes[at] ^= 1 + random.nextInt(255);
        final outcome = _agreed(bytes, 'random change $i at $at');
        if (!outcome.refused) {
          expect(outcome.bytes, _source,
              reason: 'random change $i at $at changed the output silently');
        }
      }
    });

    test('100 random spans overwritten', () {
      final random = Random(13092026);
      for (var i = 0; i < 100; i++) {
        final bytes = Uint8List.fromList(_frame);
        final at = random.nextInt(bytes.length);
        final span = 1 + random.nextInt(64);
        for (var j = at; j < bytes.length && j < at + span; j++) {
          bytes[j] = random.nextInt(256);
        }
        final outcome = _agreed(bytes, 'random span $i at $at');
        if (!outcome.refused) {
          expect(outcome.bytes, _source,
              reason: 'random span $i at $at changed the output silently');
        }
      }
    });
  });

  group('zstd refuses invalid frame header', () {
    test('reserved descriptor bit set', () {
      final bytes = Uint8List.fromList(_frame)..[4] |= 0x08;
      _refuse(bytes, 'reserved descriptor bit');
    });

    test('window wider than limit', () {
      // The widest window descriptor, 3.5 TB, which no limit allows
      _refuse(_bytes([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0xff, 0, 0, 0]),
          'window above the limit');
    });

    test('dictionary id without matching dictionary', () {
      final dictionary = ZstdDictionary(
          File('test/_data/zstd/dict-trained.dict').readAsBytesSync());
      expect(dictionary.id, isNot(0));
      _refuse(ZstdEncoder(dictionary: dictionary).encodeBytes(_source),
          'a frame naming a dictionary');
    }, testOn: 'vm');

    test('content size that frame does not produce', () {
      for (final declared in [1, 79999, 80001, 1 << 20]) {
        final frame = _declaring(declared);
        _refuse(frame, 'declared $declared against 80000');
      }
    });

    test('content size too large to allocate', () {
      // The claim alone must buy no memory: the frame is sixteen bytes
      for (final declared in [
        1 << 30,
        1 << 33,
        (1 << 40) + 1,
        0xfffffffffff,
      ]) {
        final size = Uint8List(8);
        ByteData.sublistView(size).setUint64(0, declared, Endian.little);
        _refuse(
            _bytes([
              0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0x00, ...size, //
              0x1b, 0x00, 0x00, 0x41,
            ]),
            'a frame declaring $declared bytes');
      }
    }, testOn: 'vm');

    test('header truncated inside its fields', () {
      for (final head in [
        [0x28, 0xb5, 0x2f, 0xfd],
        [0x28, 0xb5, 0x2f, 0xfd, 0xa0],
        [0x28, 0xb5, 0x2f, 0xfd, 0x00],
        [0x28, 0xb5, 0x2f, 0xfd, 0x03, 0x00, 0x01, 0x02],
      ]) {
        _refuse(_bytes(head), 'header of ${head.length} bytes');
      }
    });
  });

  group('zstd refuses invalid block', () {
    test('reserved block type', () {
      final at = _firstBlock(_plain);
      final bytes = Uint8List.fromList(_plain)..[at] |= 6;
      _refuse(bytes, 'block type three');
    });

    test('block larger than frame allows', () {
      final at = _firstBlock(_plain);
      final bytes = Uint8List.fromList(_plain);
      bytes[at] |= 0xf8;
      bytes[at + 1] = 0xff;
      bytes[at + 2] = 0xff;
      _refuse(bytes, 'block above the block maximum');
    });

    test('RLE block without byte to repeat', () {
      _refuse(_bytes([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x1b, 0x00, 0x00]),
          'RLE block without its byte');
    });

    test('raw block running past input end', () {
      _refuse(
          _bytes([0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x21, 0x00, 0x00, 1, 2]),
          'raw block of four with two bytes left');
    });

    test('frame without last block', () {
      // Every block says another follows, and then the input stops
      _refuse(
          _bytes([
            0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, //
            0x0a, 0x00, 0x00, 0x41, //
            0x0a, 0x00, 0x00, 0x42,
          ]),
          'no last block');
    });

    test('literals larger than block', () {
      final at = _firstBlock(_plain) + 3;
      final bytes = Uint8List.fromList(_plain);
      bytes[at] = 0x0e;
      bytes[at + 1] = 0xff;
      bytes[at + 2] = 0xff;
      bytes[at + 3] = 0xff;
      bytes[at + 4] = 0xff;
      _refuse(bytes, 'literals above the block maximum');
    });

    test('treeless literals without previous tree', () {
      final at = _firstBlock(_plain) + 3;
      final bytes = Uint8List.fromList(_plain);
      bytes[at] = (bytes[at] & ~3) | 3;
      _refuse(bytes, 'treeless literals in the first block');
    });
  });

  group('zstd frames around frame', () {
    test('every skippable magic is skipped', () {
      for (var low = 0x50; low <= 0x5f; low++) {
        final archive = _bytes([low, 0x2a, 0x4d, 0x18, 2, 0, 0, 0, 9, 9]);
        expect(_agreed(archive, 'skippable magic $low').bytes, isEmpty);
        expect(_agreed(_bytes([...archive, ..._frame]), 'lead $low').bytes,
            _source);
      }
    });

    test('skippable frame size past input end throws', () {
      for (final size in [1, 16, 0x7fffffff]) {
        final head = Uint8List(8);
        head.setRange(0, 4, [0x50, 0x2a, 0x4d, 0x18]);
        ByteData.sublistView(head).setUint32(4, size, Endian.little);
        _refuse(head, 'skippable frame of $size with no body');
      }
    });

    test('skippable frame between 2 frames is skipped', () {
      final archive = _bytes([
        ..._frame,
        0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 1, 2, 3, 4, //
        ..._frame,
      ]);
      expect(_agreed(archive, 'a frame either side').bytes,
          [..._source, ..._source]);
    });

    test('damaged second frame throws', () {
      final second = Uint8List.fromList(_frame);
      second[second.length - 6] ^= 0xff;
      _refuse(_bytes([..._frame, ...second]), 'the second frame is damaged');
    });

    test('input that is not zstd throws', () {
      for (final bytes in [
        [1, 2, 3, 4, 5, 6, 7, 8],
        [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0],
        [0x28, 0xb5, 0x2f, 0xfc, 0, 0, 0, 0],
        [0x50, 0x2a, 0x4d, 0x19, 0, 0, 0, 0],
      ]) {
        _refuse(_bytes(bytes), 'not a zstd frame');
      }
    });
  });

  group('zstd damaged checksum', () {
    test('each of 4 changed checksum bytes throws', () {
      for (var at = _frame.length - 4; at < _frame.length; at++) {
        final bytes = Uint8List.fromList(_frame)..[at] ^= 0xff;
        _refuse(bytes, 'checksum byte $at');
      }
    });

    test('wrong checksum passes with verify false', () {
      final bytes = Uint8List.fromList(_frame)..[_frame.length - 1] ^= 0xff;
      expect(ZstdDecoder().decodeBytes(bytes, throwOnError: true), _source);
      final output = OutputMemoryStream();
      expect(
          ZstdDecoder().decodeStream(InputMemoryStream(bytes), output,
              throwOnError: true),
          isTrue);
      expect(output.getBytes(), _source);
    });
  });

  // A threaded frame cuts its blocks where the single threaded one does not,
  // so it is a different walk for the decoder and worth damaging on its own
  group('zstd frame written by workers', () {
    late Uint8List source;
    late Uint8List frame;

    setUpAll(() async {
      source = Uint8List.fromList([
        for (var i = 0; i < 3; i++) ..._source,
        for (var i = 0; i < 800000; i++) (i * 7 + (i >> 11)) & 0xff,
      ]);
      final done = Completer<Uint8List>();
      ZstdEncoder(level: 3).encodeBytes(source,
          multithread: ZstdMultithreadOptions<Uint8List>(
              onDone: done.complete,
              onError: (error, _) => done.completeError(error),
              workers: 4));
      frame = await done.future;
    });

    test('decodes on every path', () {
      expect(_agreed(frame, 'the threaded frame').bytes, source);
    });

    test('truncated, throws on every path', () {
      for (var cut = 1; cut < frame.length; cut += 997) {
        _refuse(Uint8List.sublistView(frame, 0, cut), 'threaded cut to $cut');
      }
    });

    test('damaged, throws or decodes same on every path', () {
      final random = Random(9132026);
      for (var i = 0; i < 200; i++) {
        final bytes = Uint8List.fromList(frame);
        final at = random.nextInt(bytes.length);
        bytes[at] ^= 1 + random.nextInt(255);
        final outcome = _agreed(bytes, 'threaded change $i at $at');
        if (!outcome.refused) {
          expect(outcome.bytes, source,
              reason: 'threaded change $i at $at changed the output silently');
        }
      }
    });
  }, testOn: 'vm');

  test('damaged archive returns bytes decoded before failure', () {
    final damaged = Uint8List.fromList(_frame);
    damaged[damaged.length - 6] ^= 0xff;
    final archive = _bytes([..._frame, ...damaged]);
    expect(ZstdDecoder().decodeBytes(archive), _source);
    final output = OutputMemoryStream();
    expect(ZstdDecoder().decodeStream(InputMemoryStream(archive), output),
        isFalse);
    expect(output.getBytes(), _source);
  });

  test('damaged literals throw ArchiveException', () {
    final source = Uint8List.fromList(List.generate(
        5000,
        (i) =>
            'zstd literals need a varied alphabet '.codeUnitAt(i % 37) ^
            i ~/ 331));
    final damaged = Uint8List.fromList(const ZstdEncoder().encodeBytes(source))
      ..[8] = 0;
    expect(() => ZstdDecoder().decodeBytes(damaged), returnsNormally);
    expect(
        () => ZstdDecoder().decodeBytes(damaged, throwOnError: true),
        throwsA(predicate((error) =>
            error is ArchiveException &&
            '$error'.startsWith('ZstdLiteralsException'))));
  });
}

/// The fixture frame rewritten to declare [size] bytes of content, which is a
/// claim the blocks do not keep
Uint8List _declaring(int size) {
  final source = _plain;
  final descriptor = source[4];
  // The fixture carries its size on four bytes, which is what this rewrites
  expect(descriptor >> 6, 2, reason: 'the fixture declares its size');
  final at = _firstBlock(source) - 4;
  final bytes = Uint8List.fromList(source);
  ByteData.sublistView(bytes).setUint32(at, size, Endian.little);
  return bytes;
}

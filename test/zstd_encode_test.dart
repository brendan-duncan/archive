import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/byte_order.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/input_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:test/test.dart';

import '_zstd_util.dart';

Uint8List _pattern(int length, int Function(int) byte) =>
    Uint8List.fromList(List.generate(length, byte));

/// A stream that cannot hand out a view of its own storage, the way a file or
/// a socket cannot. Only such a stream makes the encoder slide a window, since
/// one that can view is handed straight to the whole buffer path
class _Piped extends InputStream {
  final InputMemoryStream _held;

  _Piped(Uint8List bytes)
      : _held = InputMemoryStream(bytes),
        super(byteOrder: ByteOrder.littleEndian);

  @override
  int get position => _held.position;

  @override
  set position(int v) => _held.position = v;

  @override
  int get length => _held.length;

  @override
  bool get isEOS => _held.isEOS;

  @override
  bool open() => _held.open();

  @override
  Future<void> close() => _held.close();

  @override
  void closeSync() => _held.closeSync();

  @override
  void reset() => _held.reset();

  @override
  void setPosition(int v) => _held.setPosition(v);

  @override
  void rewind([int length = 1]) => _held.rewind(length);

  @override
  void skip(int length) => _held.skip(length);

  @override
  int readInto(Uint8List into, int at, int count) =>
      _held.readInto(into, at, count);

  @override
  InputStream readBytes(int count) => _held.readBytes(count);

  @override
  int readByte() => _held.readByte();

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) =>
      _held.subset(position: position, length: length, bufferSize: bufferSize);

  @override
  Uint8List toUint8List() => _held.toUint8List();
}

class _Reserving extends OutputMemoryStream {
  final reserved = <int>[];

  @override
  void reserve(int total) {
    reserved.add(total);
    super.reserve(total);
  }
}

/// Words drawn at random from a small vocabulary, which is the shape a deeper
/// search pays off on where a plain repeat does not
Uint8List _words(int length) {
  const words = [
    'zstd',
    'window',
    'sequence',
    'literal',
    'offset',
    'match',
    'table',
    'block',
    'frame',
    'stream',
    'header',
    'entropy'
  ];
  var seed = 7;
  final text = StringBuffer();
  while (text.length < length) {
    seed = (seed * 1103515245 + 12345) & 0x3fffffff;
    text.write(words[seed % words.length]);
    text.write(seed % 11 == 0 ? '\n' : ' ');
  }
  return Uint8List.fromList(text.toString().codeUnits);
}

void main() {
  final cases = <String, Uint8List>{
    'empty': Uint8List(0),
    'one byte': Uint8List.fromList([100]),
    'eight bytes': Uint8List.fromList('epsilon '.codeUnits),
    'a byte repeated': Uint8List(5000)..fillRange(0, 5000, 0x41),
    'one block short': _pattern(131071, (i) => (i * 7) & 0xff),
    'exactly one block': _pattern(131072, (i) => (i * 7) & 0xff),
    'one byte over a block': _pattern(131073, (i) => (i * 7) & 0xff),
    'several blocks': _pattern(500000, (i) => 0x20 + (i * 7 + (i >> 5)) % 90),
    'past a single segment': _pattern(300000, (i) => (i * 2654435761) & 0xff),
    'a short phrase over and over': Uint8List.fromList(
        List.filled(400, 'the quick brown fox ').join().codeUnits),
    'text with long repeats': Uint8List.fromList(
        (List.generate(2000, (i) => 'line ${i} of a file that repeats itself\n')
                    .join() *
                3)
            .codeUnits),
    'matches across a block edge': _pattern(
        400000, (i) => 0x41 + ((i ~/ 97) % 3) * 7 + (i % 97 == 0 ? 1 : 0)),
    'incompressible':
        _pattern(200000, (i) => (i * 1103515245 + 12345) >> 7 & 0xff),
    'words drawn at random': _words(300000),
  };

  group('negative levels', () {
    // Source, level, then the length and CRC-32 of the frame ZSTD_compress2
    // of zstd 1.5.7 wrote for it, with no checksum
    const vectors = <List<Object>>[
      ['synth', -1, 88877, 0x0ca6cd6a],
      ['synth', -2, 90323, 0x0047b7b5],
      ['synth', -3, 94483, 0x18e27dea],
      ['synth', -5, 102669, 0x81795836],
      ['synth', -7, 108047, 0x936cafa1],
      ['synth', -50, 164443, 0xcf8d94ec],
      ['synth', -1000, 282727, 0x73ff1c1c],
      ['synth', -131072, 300018, 0x6c5e795e],
      ['random', -1, 50010, 0x1203b2d7],
      ['random', -131072, 50010, 0x1203b2d7],
      ['rle', -1, 8687, 0x4f0228be],
      ['rle', -2, 8744, 0x22c22872],
      ['rle', -3, 9020, 0x9b71a295],
      ['rle', -5, 9611, 0x0839c126],
      ['rle', -7, 10307, 0x6999974b],
      ['rle', -50, 39336, 0xa8ec4b6a],
      ['rle', -1000, 190688, 0x3ba34025],
      ['rle', -131072, 200015, 0x60cdf0a1],
      ['nibbles', -1, 24474, 0xfca3b2bc],
      ['nibbles', -2, 25581, 0x8b46f498],
      ['nibbles', -3, 26404, 0xe553fcb1],
      ['nibbles', -5, 27446, 0xd593b1e6],
      ['nibbles', -7, 28275, 0x4e977cd1],
      ['nibbles', -50, 30010, 0x79ec22ca],
      ['small', -1, 1268, 0x638bf30f],
      ['small', -2, 1273, 0xce97ba13],
      ['small', -3, 1327, 0x9428fcdb],
      ['small', -5, 1388, 0x67945bce],
      ['small', -7, 1603, 0xf0e7e826],
      ['small', -50, 2179, 0x7f643649],
      ['small', -1000, 2950, 0x4fbba14d],
      ['small', -131072, 3010, 0x66fa54af],
    ];
    final sources = {
      'synth': synth(300000, 1),
      'random': randomBytes(50000, 3),
      'rle': rleLiterals(200000, 4),
      'nibbles': nibbles(30000, 5),
      'small': synth(3000, 6),
    };
    for (final v in vectors) {
      final name = v[0] as String;
      final level = v[1] as int;
      test('$name at level $level is the frame zstd writes', () {
        final source = sources[name]!;
        final frame =
            ZstdEncoder(level: level).encodeBytes(source, checksum: false);
        expect([frame.length, getCrc32(frame)], [v[2], v[3]]);
        expect(ZstdDecoder().decodeBytes(frame, throwOnError: true), source);
      });
    }
  });

  group('zstd encoder', () {
    for (final entry in cases.entries) {
      final source = entry.value;
      final crc = getCrc32(source);

      test('${entry.key} decodes back', () {
        final encoded = const ZstdEncoder().encodeBytes(source);
        final decoded = ZstdDecoder()
            .decodeBytes(encoded, verify: true, throwOnError: true);
        expect(decoded.length, source.length);
        expect(getCrc32(decoded), crc);
      });

      test('${entry.key} decodes back through stream', () {
        final out = OutputMemoryStream();
        const ZstdEncoder().encodeStream(InputMemoryStream(source), out);
        final decoded = ZstdDecoder()
            .decodeBytes(out.getBytes(), verify: true, throwOnError: true);
        expect(getCrc32(decoded), crc);
      });

      test('${entry.key} frame header has correct content size', () {
        final encoded = const ZstdEncoder().encodeBytes(source);
        expect(ZstdDecoder().uncompressedSize(encoded), source.length);
      });
    }

    test('frame without checksum decodes back', () {
      final source = cases['several blocks']!;
      final encoded = const ZstdEncoder().encodeBytes(source, checksum: false);
      final decoded =
          ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true);
      expect(getCrc32(decoded), getCrc32(source));
    });

    // A frame never opens with a repeated byte block, which older decoders
    // read as the frame ending early, so the first one is coded instead
    test('repeated byte compresses to few bytes per block', () {
      final encoded =
          const ZstdEncoder().encodeBytes(Uint8List(70000), checksum: false);
      expect(encoded.length, lessThan(24));
    });

    test('repeating phrase compresses strongly', () {
      final source = cases['a short phrase over and over']!;
      final encoded = const ZstdEncoder().encodeBytes(source, checksum: false);
      expect(encoded.length * 20, lessThan(source.length));
    });

    test('sequences cover every input byte', () {
      for (final entry in cases.entries) {
        final source = entry.value;
        final encoded = const ZstdEncoder().encodeBytes(source);
        final decoded = ZstdDecoder()
            .decodeBytes(encoded, verify: true, throwOnError: true);
        expect(decoded.length, source.length, reason: entry.key);
        expect(getCrc32(decoded), getCrc32(source), reason: entry.key);
      }
    });

    // A short source on purpose: the deepest levels search hard enough that a
    // few hundred kilobytes would dominate the whole suite
    test('every level decodes back', () {
      final source = _words(30000);
      final crc = getCrc32(source);
      var first = 0;
      var last = 0;
      for (var level = 1; level <= zstdMaxLevel; level++) {
        final encoded =
            ZstdEncoder(level: level).encodeBytes(source, checksum: false);
        final decoded = ZstdDecoder().decodeBytes(encoded, throwOnError: true);
        expect(getCrc32(decoded), crc, reason: 'level $level');
        expect(encoded.length, lessThan(source.length >> 2),
            reason: 'level $level');
        if (level == 1) {
          first = encoded.length;
        }
        last = encoded.length;
      }
      // Only the two ends are compared: the table a source this small selects
      // is not monotone in the reference either, where level 2 reads worse
      // than level 1 and level 13 worse than level 12
      expect(last, lessThan(first * 3 ~/ 5));
    });

    test('level is clamped to zstdMinLevel and zstdMaxLevel', () {
      final source = cases['text with long repeats']!;
      expect(ZstdEncoder(level: 99).encodeBytes(source).length,
          ZstdEncoder(level: zstdMaxLevel).encodeBytes(source).length);
      expect(ZstdEncoder(level: zstdMinLevel - 1000).encodeBytes(source),
          ZstdEncoder(level: zstdMinLevel).encodeBytes(source));
    });

    test('higher level output is not larger on real text', () {
      final source = cases['words drawn at random']!;
      final low = ZstdEncoder(level: 1).encodeBytes(source, checksum: false);
      final high = ZstdEncoder(level: 9).encodeBytes(source, checksum: false);
      expect(high.length * 3, lessThan(low.length * 2));
    });

    test('encodeStream over memory equals encodeBytes', () {
      final source = cases['several blocks']!;
      final out = OutputMemoryStream();
      const ZstdEncoder().encodeStream(InputMemoryStream(source), out);
      expect(out.getBytes(), const ZstdEncoder().encodeBytes(source));
    });

    // A frame slides once the source passes the window plus the slack the
    // encoder keeps beside it, which is thirteen megabytes at level twelve and
    // twenty four at level sixteen. Below that the buffer holds everything and
    // nothing is reduced, so a smaller source would test nothing
    test('stream longer than window equals encodeBytes output', () {
      final source = _words(13 << 20);
      for (final level in [1, 3, 5, 6, 9, 12]) {
        final whole = ZstdEncoder(level: level).encodeBytes(source);
        final out = OutputMemoryStream();
        ZstdEncoder(level: level).encodeStream(_Piped(source), out);
        expect(out.getBytes(), whole, reason: 'level $level');
      }
    });

    // The tree and the optimal parse raise a position by two and keep a mark
    // of their own, so their tables reduce by different rules than the rest.
    // Seventeen megabytes is the least that makes both of these slide
    test('stream at levels 13 and 16 with slid tree equals encodeBytes', () {
      final source = _words(17 << 20);
      for (final level in [13, 16]) {
        final whole = ZstdEncoder(level: level).encodeBytes(source);
        final out = OutputMemoryStream();
        ZstdEncoder(level: level).encodeStream(_Piped(source), out);
        expect(out.getBytes(), whole, reason: 'level $level');
      }
    });

    test('stream shorter than window equals encodeBytes output', () {
      for (final entry in cases.entries) {
        final out = OutputMemoryStream();
        const ZstdEncoder().encodeStream(_Piped(entry.value), out);
        expect(out.getBytes(), const ZstdEncoder().encodeBytes(entry.value),
            reason: entry.key);
      }
    });

    test('stream sliding past dictionary equals encodeBytes output', () {
      final source = _words(13 << 20);
      final dictionary = ZstdDictionary(_words(1 << 16));
      for (final level in [3, 6, 12]) {
        final coder = ZstdEncoder(level: level, dictionary: dictionary);
        final out = OutputMemoryStream();
        coder.encodeStream(_Piped(source), out);
        expect(out.getBytes(), coder.encodeBytes(source),
            reason: 'level $level');
      }
    });

    test('stream without checksum equals encodeBytes output', () {
      final source = _words(13 << 20);
      const coder = ZstdEncoder();
      final out = OutputMemoryStream();
      coder.encodeStream(_Piped(source), out, checksum: false);
      expect(out.getBytes(), coder.encodeBytes(source, checksum: false));
    });

    test('slid frame decodes back', () {
      final source = _words(13 << 20);
      final out = OutputMemoryStream();
      const ZstdEncoder().encodeStream(_Piped(source), out);
      final decoded = ZstdDecoder()
          .decodeBytes(out.getBytes(), verify: true, throwOnError: true);
      expect(decoded.length, source.length);
      expect(getCrc32(decoded), getCrc32(source));
    });

    test('empty stream writes empty frame', () {
      final out = OutputMemoryStream();
      const ZstdEncoder().encodeStream(_Piped(Uint8List(0)), out);
      expect(out.getBytes(), const ZstdEncoder().encodeBytes(Uint8List(0)));
    });

    test('encodeStream reads only bytes from input position to end', () {
      final source = _words(3 << 20);
      final held = _Piped(source)..skip(1024);
      final out = OutputMemoryStream();
      const ZstdEncoder().encodeStream(held, out);
      expect(out.getBytes(),
          const ZstdEncoder().encodeBytes(Uint8List.sublistView(source, 1024)));
    });

    test('frame appended to non-empty output reserves space once', () {
      final source = _words(3 << 20);
      final prefix = _words(4 << 20);
      final out = _Reserving()..writeBytes(prefix);
      const ZstdEncoder().encodeStream(_Piped(source), out);
      final frame = const ZstdEncoder().encodeBytes(source);
      expect(out.getBytes().sublist(prefix.length), frame);
      expect(out.reserved, hasLength(1));
      expect(out.reserved.single, greaterThanOrEqualTo(out.length));
      expect(out.reserved.single - prefix.length,
          lessThanOrEqualTo(source.length + (source.length >> 7) + 64));
    });
  });
}

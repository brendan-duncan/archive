import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

// A codec has three ways in: the whole buffer, the older InputStream pair, and
// the chunked converter. They have to agree with each other where the format
// says they should, and every one of them has to read back as the original.
// Nothing here runs another program: the suite has to pass wherever it is.

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state =
        (state * 20077 + state * 16838 % 0x8000 * 0x10000 + 12345) % 0x80000000;
    // Compressible, with runs, so every path has real work to do
    bytes[i] = (state >> 16) % 4 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Uint8List _chunked(
    Converter<List<int>, List<int>> codec, Uint8List source, int piece) {
  final held = BytesBuilder(copy: false);
  final sink = codec.startChunkedConversion(_Held(held));
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    sink.add(Uint8List.sublistView(source, at, end));
  }
  sink.close();
  return held.toBytes();
}

Uint8List _old(
    void Function(InputStream, OutputStream) body, Uint8List source) {
  final output = OutputMemoryStream();
  body(InputMemoryStream(source), output);
  return output.getBytes();
}

void main() {
  final source = _source(400000, 7);

  final codecs = <String, _Paths>{
    'zstd': _Paths(
      whole: () => ZstdEncoder().encodeBytes(source),
      old: () => _old((i, o) => ZstdEncoder().encodeStream(i, o), source),
      converter: zstdCodec.encoder,
      decoder: zstdCodec.decoder,
      back: (a) =>
          ZstdDecoder().decodeBytes(a, verify: true, throwOnError: true),
      toFile: (i, o) => ZstdDecoder().decodeStream(i, o, verify: true),
      // The chunked encoder writes what ZSTD_compressStream2 writes, which is
      // a different archive from the one shot ZSTD_compress2
      chunkedMatchesWhole: false,
    ),
    'bzip2': _Paths(
      whole: () => BZip2Encoder().encodeBytes(source),
      old: () => _old((i, o) => BZip2Encoder().encodeStream(i, o), source),
      converter: bzip2Codec.encoder,
      decoder: bzip2Codec.decoder,
      back: (a) => BZip2Decoder().decodeBytes(a, verify: true),
      toFile: (i, o) => BZip2Decoder().decodeStream(i, o, verify: true),
      chunkedMatchesWhole: true,
    ),
    'xz': _Paths(
      whole: () => XZEncoder().encodeBytes(source),
      old: () => _old((i, o) => XZEncoder().encodeStream(i, o), source),
      converter: xzCodec.encoder,
      decoder: xzCodec.decoder,
      back: (a) => XZDecoder().decodeBytes(a, verify: true),
      toFile: (i, o) => XZDecoder().decodeStream(i, o, verify: true),
      chunkedMatchesWhole: true,
    ),
  };

  for (final entry in codecs.entries) {
    final name = entry.key;
    final paths = entry.value;

    group('$name: bytes, stream and converter paths', () {
      test('encodeStream output equals encodeBytes output', () {
        expect(paths.old(), paths.whole());
      });

      test('converter output does not depend on input piece sizes', () {
        final want = _chunked(paths.converter, source, source.length);
        for (final piece in [1, 4095, 65536]) {
          expect(_chunked(paths.converter, source, piece), want,
              reason: 'piece $piece');
        }
        if (paths.chunkedMatchesWhole) {
          expect(want, paths.whole());
        } else {
          expect(want, isNot(paths.whole()));
        }
      });

      test('output of all 3 paths decodes to original', () {
        for (final archive in [
          paths.whole(),
          paths.old(),
          _chunked(paths.converter, source, 8192)
        ]) {
          expect(paths.back(archive), source);
          expect(_chunked(paths.decoder, archive, 997), source);
        }
      });

      test('output of all 3 paths read from disk decodes to original',
          testOn: 'vm', () {
        // The way a reader gets an archive: a file, decoded a piece at a time
        // into another file, neither side ever held whole
        final directory = Directory.systemTemp.createTempSync('codec_paths');
        try {
          for (final archive in [
            paths.whole(),
            paths.old(),
            _chunked(paths.converter, source, 8192)
          ]) {
            final archivePath = '${directory.path}/probe.$name';
            final outputPath = '${directory.path}/probe.bin';
            File(archivePath).writeAsBytesSync(archive);
            final input = InputFileStream(archivePath);
            final output = OutputFileStream(outputPath);
            paths.toFile(input, output);
            output.closeSync();
            input.closeSync();
            expect(File(outputPath).readAsBytesSync(), source);
          }
        } finally {
          directory.deleteSync(recursive: true);
        }
      });
    });
  }
}

class _Paths {
  final Uint8List Function() whole;
  final Uint8List Function() old;
  final Converter<List<int>, List<int>> converter;
  final Converter<List<int>, List<int>> decoder;
  final Uint8List Function(Uint8List) back;

  /// The same decode over a file, which is the path a reader takes
  final void Function(InputStream, OutputStream) toFile;
  final bool chunkedMatchesWhole;

  const _Paths({
    required this.whole,
    required this.old,
    required this.converter,
    required this.decoder,
    required this.back,
    required this.toFile,
    required this.chunkedMatchesWhole,
  });
}

class _Held implements Sink<List<int>> {
  _Held(this._held);

  final BytesBuilder _held;

  @override
  void add(List<int> data) => _held.add(data);

  @override
  void close() {}
}

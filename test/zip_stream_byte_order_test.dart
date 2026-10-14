import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/zlib/_zlib_encoder.dart';
import 'package:test/test.dart';

/// The end of central directory signature, which every reader looks for first
const _eocd = [0x50, 0x4b, 0x05, 0x06];

/// The data descriptor signature, written behind the data under bit 3
const _descriptor = [0x50, 0x4b, 0x07, 0x08];

bool _contains(Uint8List bytes, List<int> signature) {
  outer:
  for (var i = 0; i + signature.length <= bytes.length; i++) {
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) {
        continue outer;
      }
    }
    return true;
  }
  return false;
}

List<ArchiveFile> _entries() => [
      ArchiveFile.bytes(
          'one.txt',
          Uint8List.fromList(utf8
              .encode('the quick brown fox jumps over the lazy dog\n' * 200))),
      ArchiveFile.bytes('two.txt',
          Uint8List.fromList(utf8.encode('second entry payload\n' * 50))),
    ];

Future<Uint8List> _encode(ZipEncoderTransformer encoder) async {
  final out = <int>[];
  await for (final piece
      in Stream<ArchiveFile>.fromIterable(_entries()).transform(encoder)) {
    out.addAll(piece);
  }
  return Uint8List.fromList(out);
}

void main() {
  // The web zlib encoder writes the zlib header and its adler32 big-endian.
  // Deflating straight into the archive let that order stay on the caller's
  // stream, and every zip field written behind the data came out reversed.
  // On the VM `platformZLibEncoder` never touches the order, so this only ever
  // failed once compiled for the browser or node
  group('deflate keeps byte order of output stream', () {
    // `ZipEncoder` builds a `Random.secure()` whatever the password, and that
    // constructor throws under the node runner, so the archive itself is only
    // built here on the VM. The two order checks below are what cover the web
    test(
        'streamed encoder in big-endian output still ends with central directory',
        testOn: 'vm', () async {
      final bytes = await _encode(zipCodec.encoder);
      expect(_contains(bytes, _descriptor), isTrue,
          reason: 'bit 3 is set, so a data descriptor has to follow the data');
      expect(_contains(bytes, _eocd), isTrue,
          reason: 'without this signature no reader can open the archive');
    });

    test('streamed encoder output decodes back', testOn: 'vm', () async {
      final bytes = await _encode(zipCodec.encoder);
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((f) => f.name), ['one.txt', 'two.txt']);
      expect(archive.files[0].readBytes(), _entries()[0].readBytes());
      expect(archive.files[1].readBytes(), _entries()[1].readBytes());
    });

    test('buffered encoder output is unchanged', testOn: 'vm', () async {
      final bytes = await _encode(const ZipCodec(streamed: false).encoder);
      expect(_contains(bytes, _eocd), isTrue);
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((f) => f.name), ['one.txt', 'two.txt']);
    });

    test('raw deflate keeps byte order set on output', () {
      final output = OutputMemoryStream(byteOrder: ByteOrder.littleEndian);
      platformZLibEncoder.encodeStream(
          InputMemoryStream(utf8.encode('payload ' * 100)), output,
          level: 6, raw: true);
      expect(output.byteOrder, ByteOrder.littleEndian);
    });

    test('zlib deflate restores byte order of output', () {
      final output = OutputMemoryStream(byteOrder: ByteOrder.littleEndian);
      platformZLibEncoder.encodeStream(
          InputMemoryStream(utf8.encode('payload ' * 100)), output,
          level: 6);
      expect(output.byteOrder, ByteOrder.littleEndian);
    });
  });
}

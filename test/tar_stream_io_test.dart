@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Stream<List<int>> _pieces(Uint8List bytes, int piece) async* {
  for (var at = 0; at < bytes.length; at += piece) {
    final end = at + piece < bytes.length ? at + piece : bytes.length;
    yield Uint8List.sublistView(bytes, at, end);
  }
}

/// Name, size and content of every entry, as nested lists: a record of a
/// `Uint8List` compares by identity, which would pass nothing
Future<List<List<Object>>> _stream(Uint8List archive, int piece) async {
  final held = <List<Object>>[];
  await for (final entry
      in _pieces(archive, piece).transform(tarCodec.decoder)) {
    final bytes = <int>[];
    var length = 0;
    var crc = 0;
    await for (final part in entry.content) {
      length += part.length;
      crc = getCrc32(part, crc);
      if (length <= _heldContent) {
        bytes.addAll(part);
      }
    }
    held.add(entry.isDirectory
        ? [entry.name, 0, <int>[]]
        : [
            entry.name,
            entry.size,
            length <= _heldContent ? bytes : '$length bytes, CRC32 $crc'
          ]);
  }
  return held;
}

const _heldContent = 1 << 20;

Object _bytes(List<int> bytes) => bytes.length <= _heldContent
    ? bytes.toList()
    : '${bytes.length} bytes, CRC32 ${getCrc32(bytes)}';

List<List<Object>> _whole(Uint8List archive) => TarDecoder()
    .decodeBytes(archive)
    .files
    .map((f) => <Object>[
          f.name,
          f.size,
          f.isFile ? _bytes(f.content) : <int>[],
        ])
    .toList();

void main() {
  final directory = Directory('test/_data/tar');
  final archives = directory
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      // writer-big.tar names an entry of 16 GB inside a 4 KB file. The whole
      // decoder clamps the read and reports what it found, the streamed one
      // says the archive ended, so the two have nothing to compare
      .where((name) => name.endsWith('.tar') && name != 'writer-big.tar')
      .toList()
    ..sort();

  group('tar chunked encoder', () {
    test('entry read from file is written in pieces of 64 KiB', () async {
      final directory = await Directory.systemTemp.createTemp('tar_stream');
      try {
        final path = '${directory.path}/big.bin';
        final content = _source(500000, 13);
        File(path).writeAsBytesSync(content);
        final input = InputFileStream(path);
        final entry = ArchiveFile.stream('big.bin', input);
        final held = _Held();
        TarChunkedEncoder(held)
          ..add(entry)
          ..close();
        await input.close();
        final back = TarDecoder().decodeBytes(held.bytes);
        expect(back.files.single.content, content);
        // The file is half a megabyte, handed over in pieces of 64 KiB
        expect(held.pieces, greaterThan(4));
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('tar stream reader', () {
    for (final name in archives) {
      test('$name stream decode equals TarDecoder.decodeBytes', () async {
        final archive = File('${directory.path}/$name').readAsBytesSync();
        final want = _whole(archive);
        for (final piece in [1, 137, 512, 4096, archive.length]) {
          expect(await _stream(archive, piece), want,
              reason: '$name piece $piece');
        }
      });
    }

    test('GNU incremental header keeps entry name', () async {
      final bytes =
          File('test/_data/tar/gnu-incremental.tar').readAsBytesSync();
      final read = await _stream(bytes, 512);
      expect(read.map((e) => e[0]), ['test2/', 'test2/foo', 'test2/sparse']);
    });

    test('GNU dumpdir entry is directory', () async {
      final bytes =
          File('test/_data/tar/gnu-incremental.tar').readAsBytesSync();
      final types = <String, TarEntryType>{};
      await for (final entry
          in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        types[entry.name] = entry.type;
        await entry.content.drain<void>();
      }
      expect(types['test2/'], TarEntryType.directory);
      expect(types['test2/foo'], TarEntryType.file);
    });

    test('reads .tar.gz piece by piece through gzip.decoder', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('big.bin', _source(200000, 19)))
        ..add(ArchiveFile.string('note.txt', 'at the end'));
      final tar = TarEncoder().encodeBytes(archive);
      final gz = Uint8List.fromList(gzip.encode(tar));
      final names = <String>[];
      var bytes = 0;
      await for (final entry in _pieces(gz, 4096)
          .transform(gzip.decoder)
          .transform(tarCodec.decoder)) {
        names.add(entry.name);
        await for (final piece in entry.content) {
          bytes += piece.length;
        }
      }
      expect(names, ['big.bin', 'note.txt']);
      expect(bytes, 200000 + 10);
    });

    // Reading input past tar end fails on bytes after compressed stream, which
    // bsdtar and Python tarfile accept
    test('bytes after compressed stream do not fail archive', () async {
      final content = _source(3000, 29);
      final tar = TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', content)));
      final compressed = {
        'gzip': (gzip.encode(tar), gzip.decoder),
        'zstd': (zstdCodec.encode(tar), zstdCodec.decoder),
      };
      final tails = {
        'zero padding': Uint8List(512),
        'signature': utf8.encode('SIGNATURE:3045022100abcdef'),
      };
      for (final format in compressed.entries) {
        for (final tail in tails.entries) {
          final bytes = Uint8List.fromList([...format.value.$1, ...tail.value]);
          for (final piece in [512, bytes.length]) {
            final read = <String, List<int>>{};
            await for (final entry in _pieces(bytes, piece)
                .transform(format.value.$2)
                .transform(tarCodec.decoder)) {
              read[entry.name] = await entry.content
                  .fold<List<int>>(<int>[], (held, p) => held..addAll(p));
            }
            expect(read.keys, ['a.bin'],
                reason: '${format.key}, ${tail.key}, pieces of $piece');
            expect(read['a.bin'], content,
                reason: '${format.key}, ${tail.key}, pieces of $piece');
          }
        }
      }
    });
  });
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;
  var closed = false;

  int get pieces => _pieces.length;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {
    closed = true;
  }

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

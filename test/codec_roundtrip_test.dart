@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

typedef _Encode = FutureOr<Uint8List> Function(Uint8List source);
typedef _Decode = FutureOr<Uint8List> Function(Uint8List archive);

const _words = [
  'alpha ',
  'beta ',
  'archive ',
  'zstd ',
  'deflate ',
  '0123456789 ',
  'lorem ipsum ',
];

// Random bytes between repeated words, so both literals and matches are coded
Uint8List _source(int length) {
  final bytes = Uint8List(length);
  var state = length;
  var at = 0;
  while (at < length) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    if ((state >> 16) % 8 < 3) {
      bytes[at++] = (state >> 8) & 0xff;
      continue;
    }
    for (final unit in _words[(state >> 12) % _words.length].codeUnits) {
      if (at == length) {
        break;
      }
      bytes[at++] = unit;
    }
  }
  return bytes;
}

// Mostly random bytes, so blocks are close to incompressible and matches rare
Uint8List _noise(int length) {
  final bytes = Uint8List(length);
  var state = length;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 16) % 4 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Stream<List<int>> _pieces(Uint8List bytes) => Stream.fromIterable([
      for (var at = 0; at < bytes.length; at += 4093)
        Uint8List.sublistView(bytes, at, min(at + 4093, bytes.length))
    ]);

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final held = BytesBuilder(copy: false);
  await for (final piece in stream) {
    held.add(piece);
  }
  return held.takeBytes();
}

Future<Uint8List> _through(
        StreamTransformer<List<int>, List<int>> codec, Uint8List bytes) =>
    _collect(_pieces(bytes).transform(codec));

Uint8List _stream(
    void Function(InputStream, OutputStream) body, Uint8List source) {
  final output = OutputMemoryStream();
  body(InputMemoryStream(source), output);
  return output.getBytes();
}

var _files = 0;

String _write(Uint8List bytes) {
  final path = '$testOutputPath/roundtrip_${_files++}';
  io.File(path).writeAsBytesSync(bytes);
  return path;
}

Uint8List _fromMemory(
    bool Function(InputStream, OutputStream) decode, Uint8List archive) {
  final output = OutputMemoryStream();
  expect(decode(InputMemoryStream(archive), output), isTrue);
  return output.getBytes();
}

Uint8List _fromFile(
    bool Function(InputStream, OutputStream) decode, Uint8List archive) {
  final input = InputFileStream(_write(archive));
  final output = OutputMemoryStream();
  try {
    expect(decode(input, output), isTrue);
  } finally {
    input.closeSync();
  }
  return output.getBytes();
}

Uint8List _toSink(
    bool Function(InputStream, OutputStream) decode, Uint8List archive) {
  final held = BytesBuilder(copy: false);
  final output =
      SinkOutputStream(ChunkedConversionSink<List<int>>.withCallback((pieces) {
    for (final piece in pieces) {
      held.add(piece);
    }
  }));
  expect(decode(InputMemoryStream(archive), output), isTrue);
  output
    ..flush()
    ..sink.close();
  return held.takeBytes();
}

const _small = [0, 1, 100000];

// Past a zstd block, a bzip2 block of 900 KB, a web inflate flush of 1 MB and
// two zstd jobs of 512 KB, none of which 100 KB reaches
const _large = [..._small, 1100000];

void _matrix(
    String name, Map<String, _Encode> encoders, Map<String, _Decode> decoders,
    {List<int> sizes = _small,
    void Function(Uint8List archive, Uint8List source)? check}) {
  test('$name: output of every encoder decodes through every decoder',
      () async {
    for (final size in sizes) {
      for (final source in [_source(size), if (size == 100000) _noise(size)]) {
        for (final MapEntry(key: how, value: encode) in encoders.entries) {
          final archive = await encode(source);
          check?.call(archive, source);
          for (final MapEntry(key: back, value: decode) in decoders.entries) {
            expect(await decode(archive), source,
                reason: '$how -> $back, $size bytes');
          }
        }
      }
    }
  });
}

List<List<Object?>> _describe(Iterable<ArchiveFile> files) => [
      for (final file in files)
        [
          file.name.endsWith('/')
              ? file.name.substring(0, file.name.length - 1)
              : file.name,
          file.isSymbolicLink
              ? 'link'
              : file.isDirectory
                  ? 'dir'
                  : 'file',
          file.isFile && !file.isSymbolicLink
              ? List<int>.from(file.content)
              : <int>[],
          file.isSymbolicLink ? file.symbolicLink : null,
        ]
    ];

Future<List<List<Object?>>> _describeEntries(Stream<TarEntry> entries) async {
  final held = <List<Object?>>[];
  await for (final entry in entries) {
    final bytes = <int>[];
    await for (final part in entry.content) {
      bytes.addAll(part);
    }
    final name = entry.name.endsWith('/')
        ? entry.name.substring(0, entry.name.length - 1)
        : entry.name;
    held.add([
      name,
      entry.isSymbolicLink
          ? 'link'
          : entry.isDirectory
              ? 'dir'
              : 'file',
      entry.isFile ? bytes : <int>[],
      entry.isSymbolicLink ? entry.symbolicLink : null,
    ]);
  }
  return held;
}

bool _contains(List<int> bytes, List<int> part) {
  outer:
  for (var i = 0; i + part.length <= bytes.length; i++) {
    for (var j = 0; j < part.length; j++) {
      if (bytes[i + j] != part[j]) {
        continue outer;
      }
    }
    return true;
  }
  return false;
}

Archive _archive(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return archive;
}

List<ArchiveFile> _entries(String accented, {int large = 100000}) => [
      ArchiveFile.bytes('a.txt', _source(1000)),
      ArchiveFile.directory('dir/'),
      ArchiveFile.bytes('dir/${'d' * 150}.bin', _source(large)),
      ArchiveFile.bytes('$accented.txt', _source(10)),
      ArchiveFile.bytes('empty', Uint8List(0)),
      ArchiveFile.symlink('link', 'a.txt'),
    ];

void main() {
  group('zstd', () {
    final dictionary = ZstdDictionary(
        io.File('test/_data/zstd/dict-trained.dict').readAsBytesSync());
    for (final (label, level, checksum, dict) in [
      ('level 1', 1, true, null),
      ('default level', 3, true, null),
      ('level 19', 19, true, null),
      ('no frame checksum', 3, false, null),
      ('dictionary', 3, true, dictionary),
    ]) {
      final encoder = ZstdEncoder.withDictionary(dict, level: level);
      final codec =
          ZstdCodec(level: level, frameChecksum: checksum, dictionary: dict);
      final decoder = ZstdDecoder.withDictionary(dict);
      _matrix(
          'zstd $label',
          {
            'encodeBytes': (s) => encoder.encodeBytes(s, checksum: checksum),
            'encodeStream': (s) => _stream(
                (i, o) => encoder.encodeStream(i, o, checksum: checksum), s),
            'converter': (s) => _through(codec.encoder, s),
          },
          {
            'decodeBytes': (a) =>
                decoder.decodeBytes(a, verify: true, throwOnError: true),
            'decodeStream': (a) => _fromMemory(
                (i, o) => decoder.decodeStream(i, o, verify: true), a),
            'decodeStream from a file': (a) => _fromFile(
                (i, o) => decoder.decodeStream(i, o, verify: true), a),
            'converter': (a) => _through(codec.decoder, a),
          },
          sizes: label == 'default level' ? _large : _small,
          check: (archive, source) {
        expect(archive[4] & 4 != 0, checksum, reason: 'checksum flag');
        if (dict != null) {
          expect(archive[4] & 3, isNot(0), reason: 'dictionary ID flag');
        }
      });
    }

    test('zstd level changes output of every encoder', () async {
      final source = _source(100000);
      Future<List<int>> sizes(int level) async => [
            ZstdEncoder(level: level).encodeBytes(source).length,
            _stream(ZstdEncoder(level: level).encodeStream, source).length,
            (await _through(ZstdCodec(level: level).encoder, source)).length,
          ];
      final fast = await sizes(1);
      final best = await sizes(19);
      for (var i = 0; i < fast.length; i++) {
        expect(best[i], lessThan(fast[i]), reason: 'path $i');
      }
    });

    _matrix(
        'zstd on workers',
        {
          'encodeBytes on workers': (s) {
            final done = Completer<Uint8List>();
            ZstdEncoder().encodeBytes(s,
                multithread: ZstdMultithreadOptions<Uint8List>(
                    onDone: done.complete,
                    onError: done.completeError,
                    workers: 2,
                    jobSize: 512 * 1024));
            return done.future;
          },
          'converter on workers': (s) => _through(
              const ZstdCodec(
                      multithread: ZstdMultithreadOptions.converter(
                          workers: 2, jobSize: 512 * 1024))
                  .encoder,
              s),
        },
        {
          'decodeBytes': (a) =>
              ZstdDecoder().decodeBytes(a, verify: true, throwOnError: true),
          'converter': (a) => _through(zstdCodec.decoder, a),
        },
        sizes: _large, check: (archive, source) {
      if (source.length > 512 * 1024) {
        expect(archive, isNot(ZstdEncoder().encodeBytes(source)),
            reason: 'the input is split into jobs');
      }
    });
  });

  group('xz', () {
    for (final check in XZCheck.values) {
      final codec = XzCodec(check: check);
      _matrix('xz ${check.name}', {
        'encodeBytes': (s) => XZEncoder().encodeBytes(s, check: check),
        'encodeStream': (s) =>
            _stream((i, o) => XZEncoder().encodeStream(i, o, check: check), s),
        'converter': (s) => _through(codec.encoder, s),
      }, {
        'decodeBytes': (a) =>
            XZDecoder().decodeBytes(a, verify: true, throwOnError: true),
        'decodeStream': (a) => _fromMemory(
            (i, o) => XZDecoder().decodeStream(i, o, verify: true), a),
        'decodeStream from a file': (a) => _fromFile(
            (i, o) => XZDecoder().decodeStream(i, o, verify: true), a),
        'converter': (a) => _through(codec.decoder, a),
        if (check == XZCheck.crc64) ...{
          'decodeBytes on workers': (a) {
            final done = Completer<Uint8List>();
            XZDecoder().decodeBytes(a,
                verify: true,
                multithread: XZMultithreadOptions<Uint8List>(
                    onDone: done.complete,
                    onError: done.completeError,
                    workers: 2));
            return done.future;
          },
          'decodeStream from a file on workers': (a) {
            final done = Completer<bool>();
            final input = InputFileStream(_write(a));
            final output = OutputMemoryStream();
            XZDecoder().decodeStream(input, output,
                verify: true,
                multithread: XZMultithreadOptions<bool>(
                    onDone: done.complete,
                    onError: done.completeError,
                    workers: 2));
            return done.future.then((ok) {
              input.closeSync();
              expect(ok, isTrue);
              return output.getBytes();
            });
          },
          'converter on workers': (a) => _through(
              const XzCodec(
                      multithread: XZMultithreadOptions.converter(workers: 2))
                  .decoder,
              a),
        },
      }, check: (archive, source) {
        const ids = {
          XZCheck.none: 0,
          XZCheck.crc32: 1,
          XZCheck.crc64: 4,
          XZCheck.sha256: 10,
        };
        expect(archive[7], ids[check], reason: 'check type in stream flags');
      });
    }
  });

  group('bzip2', () {
    for (final blockSize in [1, 9]) {
      final codec = BZip2Codec(blockSize100k: blockSize);
      _matrix(
          'bzip2 block size $blockSize',
          {
            'encodeBytes': (s) =>
                BZip2Encoder().encodeBytes(s, blockSize100k: blockSize),
            'encodeStream': (s) => _stream(
                (i, o) =>
                    BZip2Encoder().encodeStream(i, o, blockSize100k: blockSize),
                s),
            'converter': (s) => _through(codec.encoder, s),
          },
          {
            'decodeBytes': (a) =>
                BZip2Decoder().decodeBytes(a, verify: true, throwOnError: true),
            'decodeStream': (a) => _fromMemory(
                (i, o) => BZip2Decoder().decodeStream(i, o, verify: true), a),
            'decodeStream from a file': (a) => _fromFile(
                (i, o) => BZip2Decoder().decodeStream(i, o, verify: true), a),
            'converter': (a) => _through(codec.decoder, a),
          },
          sizes: blockSize == 9 ? _large : _small,
          check: (archive, source) =>
              expect(archive[3], 0x30 + blockSize, reason: 'block size'));
    }
  });

  final deflate = {
    'gzip': (
      nativeBytes: (Uint8List s, int? l) =>
          const GZipEncoder().encodeBytes(s, level: l),
      nativeStream: (InputStream i, OutputStream o, int? l) =>
          const GZipEncoder().encodeStream(i, o, level: l),
      webBytes: (Uint8List s, int? l) =>
          const GZipEncoderWeb().encodeBytes(s, level: l),
      webStream: (InputStream i, OutputStream o, int? l) =>
          const GZipEncoderWeb().encodeStream(i, o, level: l),
      native: const GZipDecoder().decodeBytes,
      nativeStream_: const GZipDecoder().decodeStream,
      web: const GZipDecoderWeb().decodeBytes,
      webStream_: const GZipDecoderWeb().decodeStream,
      dart: io.gzip,
    ),
    'zlib': (
      nativeBytes: (Uint8List s, int? l) =>
          const ZLibEncoder().encodeBytes(s, level: l),
      nativeStream: (InputStream i, OutputStream o, int? l) =>
          const ZLibEncoder().encodeStream(i, o, level: l),
      webBytes: (Uint8List s, int? l) =>
          const ZLibEncoderWeb().encodeBytes(s, level: l),
      webStream: (InputStream i, OutputStream o, int? l) =>
          const ZLibEncoderWeb().encodeStream(i, o, level: l),
      native: const ZLibDecoder().decodeBytes,
      nativeStream_: const ZLibDecoder().decodeStream,
      web: const ZLibDecoderWeb().decodeBytes,
      webStream_: const ZLibDecoderWeb().decodeStream,
      dart: io.zlib,
    ),
  };
  for (final MapEntry(key: format, value: f) in deflate.entries) {
    group(format, () {
      for (final level in [null, 1, 9]) {
        _matrix(
            '$format level ${level ?? 'default'}',
            {
              'native encodeBytes': (s) => f.nativeBytes(s, level),
              'native encodeStream': (s) =>
                  _stream((i, o) => f.nativeStream(i, o, level), s),
              'web encodeBytes': (s) => f.webBytes(s, level),
              'web encodeStream': (s) =>
                  _stream((i, o) => f.webStream(i, o, level), s),
            },
            {
              'native decodeBytes': (a) =>
                  f.native(a, verify: true, throwOnError: true),
              'native decodeStream': (a) =>
                  _fromMemory((i, o) => f.nativeStream_(i, o, verify: true), a),
              'native decodeStream from a file': (a) =>
                  _fromFile((i, o) => f.nativeStream_(i, o, verify: true), a),
              'native decodeStream into a sink': (a) =>
                  _toSink((i, o) => f.nativeStream_(i, o, verify: true), a),
              'web decodeBytes': (a) =>
                  f.web(a, verify: true, throwOnError: true),
              'web decodeStream': (a) =>
                  _fromMemory((i, o) => f.webStream_(i, o, verify: true), a),
              'web decodeStream from a file': (a) =>
                  _fromFile((i, o) => f.webStream_(i, o, verify: true), a),
              'web decodeStream into a sink': (a) =>
                  _toSink((i, o) => f.webStream_(i, o, verify: true), a),
              'dart:io': (a) => Uint8List.fromList(f.dart.decode(a)),
            },
            sizes: level == null ? _large : _small);
      }

      test('$format level changes output of every encoder', () {
        final source = _source(100000);
        final paths = {
          'native encodeBytes': (int level) => f.nativeBytes(source, level),
          'native encodeStream': (int level) =>
              _stream((i, o) => f.nativeStream(i, o, level), source),
          'web encodeBytes': (int level) => f.webBytes(source, level),
          'web encodeStream': (int level) =>
              _stream((i, o) => f.webStream(i, o, level), source),
        };
        for (final MapEntry(key: how, value: encode) in paths.entries) {
          expect(encode(9).length, lessThan(encode(1).length), reason: how);
        }
      });
    });
  }

  group('tar', () {
    for (final (label, encoding) in [('utf8', utf8), ('latin1', latin1)]) {
      test('tar $label: output of every encoder decodes through every decoder',
          () async {
        final entries = _entries('café');
        final want = _describe(entries);
        final codec = TarCodec(filenameEncoding: encoding);
        final archives = <String, Uint8List>{
          'encodeBytes': TarEncoder(filenameEncoding: encoding)
              .encodeBytes(_archive(entries)),
          'converter': await _collect(
              Stream.fromIterable(entries).transform(codec.encoder)),
        };
        for (final MapEntry(key: how, value: archive) in archives.entries) {
          expect(_contains(archive, encoding.encode('café')), isTrue,
              reason: '$how writes names in $label');
          final decoder = TarDecoder(filenameEncoding: encoding);
          expect(
              _describe(decoder.decodeBytes(archive, verify: true).files), want,
              reason: '$how -> decodeBytes');
          final input = InputFileStream(_write(archive));
          try {
            expect(_describe(decoder.decodeStream(input, verify: true).files),
                want,
                reason: '$how -> decodeStream from a file');
          } finally {
            input.closeSync();
          }
          expect(
              await _describeEntries(_pieces(archive).transform(codec.decoder)),
              want,
              reason: '$how -> converter');
        }
      });
    }
  });

  group('zip', () {
    for (final (password, streamed, level) in [
      (null, false, 1),
      (null, false, 9),
      (null, true, 1),
      (null, true, 9),
      ('pw', false, 6),
      ('pässwort', true, 6),
    ]) {
      final label =
          'password ${password ?? 'none'}, streamed $streamed, level $level';
      // Decryption dominates the time, so encrypted entries stay small
      final size = password == null ? 30000 : 3000;
      test('zip $label: output of every encoder decodes through every decoder',
          () async {
        final entries = [
          ..._entries('café', large: size * 3),
          for (final type in CompressionType.values)
            ArchiveFile.bytes('${type.name}.bin', _source(size))
              ..compression = type,
        ];
        final want = _describe(entries);
        final codec =
            ZipCodec(password: password, streamed: streamed, level: level);
        final archives = <String, Uint8List>{
          'encodeBytes': ZipEncoder(password: password, streamed: streamed)
              .encodeBytes(_archive(entries), level: level),
          'converter': await _collect(
              Stream.fromIterable(entries).transform(codec.encoder)),
        };
        for (final MapEntry(key: how, value: archive) in archives.entries) {
          final decoded = ZipDecoder()
              .decodeBytes(archive, verify: true, password: password)
              .files;
          expect(_describe(decoded), want, reason: '$how -> decodeBytes');
          for (final type in CompressionType.values) {
            // There is no LZMA encoder, so an LZMA entry is deflated
            expect(
                decoded
                    .firstWhere((f) => f.name == '${type.name}.bin')
                    .compression,
                type == CompressionType.lzma ? CompressionType.deflate : type,
                reason: '$how ${type.name}');
          }
          if (password == null) {
            expect(archive[6] & 8 != 0, streamed, reason: '$how streamed');
          } else {
            expect(
                () => ZipDecoder()
                    .decodeBytes(archive)
                    .files
                    .firstWhere((f) => f.name == 'a.txt')
                    .content,
                throwsA(isA<ArchivePasswordException>()),
                reason: '$how encrypts');
          }
          final input = InputFileStream(_write(archive));
          try {
            expect(
                _describe(ZipDecoder()
                    .decodeStream(input, verify: true, password: password)
                    .files),
                want,
                reason: '$how -> decodeStream from a file');
          } finally {
            input.closeSync();
          }
        }
      });
    }

    test('zip level changes output of every encoder', () async {
      final entries = [ArchiveFile.bytes('a.bin', _source(100000))];
      Future<List<int>> sizes(int level) async => [
            ZipEncoder().encodeBytes(_archive(entries), level: level).length,
            (await _collect(Stream.fromIterable(entries)
                    .transform(ZipCodec(level: level).encoder)))
                .length,
          ];
      final fast = await sizes(1);
      final best = await sizes(9);
      for (var i = 0; i < fast.length; i++) {
        expect(best[i], lessThan(fast[i]), reason: 'path $i');
      }
    });

    test(
        'zip latin1 names: output of every encoder decodes through every decoder',
        () async {
      final entries = [ArchiveFile.bytes('café.txt', _source(100))];
      const codec = ZipCodec(filenameEncoding: latin1);
      final archives = <String, Uint8List>{
        'encodeBytes':
            ZipEncoder(filenameEncoding: latin1).encodeBytes(_archive(entries)),
        'converter': await _collect(
            Stream.fromIterable(entries).transform(codec.encoder)),
      };
      for (final MapEntry(key: how, value: archive) in archives.entries) {
        expect(_contains(archive, latin1.encode('café')), isTrue, reason: how);
        expect(
            _describe(ZipDecoder(filenameEncoding: latin1)
                .decodeBytes(archive, verify: true)
                .files),
            _describe(entries),
            reason: how);
      }
    });
  });
}

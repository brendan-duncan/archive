# Streams and isolates

## Dart async* StreamTransformers/ByteConversionSink/Converter support

Codecs that take data as it arrives expose a `Codec` with a converter for each
direction, the same layout `dart:io` uses for `gzip`. Every class named `...Converter`
converts bytes to bytes, like a `dart:convert` `Converter`. tar and zip work with
entries on one side, so they use `StreamTransformer`s instead:
`TarDecoderTransformer`, `TarEncoderTransformer` and `ZipEncoderTransformer`.
Both kinds are used the same way, through `.transform`.

This is separate from `decodeStream` and `encodeStream`. Those take an `InputStream`
and an `OutputStream`, process the whole archive in one call, and do not read a
Dart `Stream`.

| codec | decoding                             | encoding                                     |
|-------|--------------------------------------|----------------------------------------------|
| xz    | `xzCodec.decoder`                    | `xzCodec.encoder` (stores, doesn't compress) |
| zstd  | `zstdCodec.decoder`                  | `zstdCodec.encoder`                          |
| bzip2 | `bzip2Codec.decoder`                 | `bzip2Codec.encoder`                         |
| tar   | `tarCodec.decoder`                   | `tarCodec.encoder`                           |
| zip   | `-- (impractical by format)*`        | `zipCodec.encoder**`                         |
| zlib  | `-- (dart already has zlib.decoder)` | `-- (dart already has zlib.encoder)`         |
| gzip  | `-- (dart already has gzip.decoder)` | `-- (dart already has gzip.encoder)`         |
> *Zip stores its central directory at the end of the file, so a decoder converter is of no use.
> Reading a zip needs the end of the archive, and a `Stream` can only be read forward.
>
> **`zipCodec.encoder` uses `streamed: true` by default. For a deflated entry, with or without a password, it
> sets general purpose bit 3, writes zeros for the CRC and sizes in the local header, and writes the
> real values in a data descriptor after the entry, so the entry is not held in memory. For the
> layout `ZipEncoder` writes, use `const ZipCodec(streamed: false)`.

This decodes an xz file as the bytes arrive, on one thread. It holds the dictionary size set
in the archive and one chunk, not the whole archive:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

await for (final piece
    in File('data.xz').openRead().transform(xzCodec.decoder)) {
  // piece is the next part of the decoded data
}
```

This downloads a `.tar.zst` and unpacks it as it arrives, without holding the response body
in memory:

```dart
import 'package:archive/archive.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

final request =
    await HttpClient().getUrl(Uri.parse('https://example.com/data.tar.zst'));
final HttpClientResponse response = await request.close();

await for (final TarEntry entry in response
    .transform(zstdCodec.decoder)
    .transform(tarCodec.decoder)) {
  final target = p.join('out', entry.name);
  if (!p.isWithin('out', target)) continue; // `../` would escape out/
  if (entry.type == TarEntryType.file) {
    await File(target).create(recursive: true);
    // A content piece is a view into the input stream's buffer, and the bytes stay
    // correct only until the next piece is read. A piece used after the loop can hold
    // the bytes of a later piece and nothing throws, so copy a piece you keep.
    await entry.content.pipe(File(target).openWrite());
  }
}
```

An entry's `content` reads the bytes that follow its header in the same stream,
so read it inside the loop body, before the next entry. The content of a skipped entry
is discarded automatically. If you keep an entry and read its `content` after the loop
has moved on, it throws `StateError`.

Encoding works the same way. A stream source and a stream destination need no buffer
between them:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

final out = File('data.xz').openWrite();
await File('data')
    .openRead()
    .transform(xzCodec.encoder)
    .pipe(out);
```

If reading or encoding fails, `pipe` throws and `out` is closed, but `data.xz`
stays on disk. It is empty if the failure happens before any output is written, and
truncated if it happens later. Delete it if you do not need a partial file.

This packs a directory into a `.tar.zst` and uploads it without a temporary file:

```dart
Stream<ArchiveFile> filesOf(Directory dir) async* {
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      final input = InputFileStream(entity.path);
      try {
        yield ArchiveFile.stream(
            p.relative(entity.path, from: dir.path), input);
      } finally {
        // Runs once the encoder has written the entry, or when the stream is cancelled
        await input.close();
      }
    }
  }
}

final upload =
    await HttpClient().putUrl(Uri.parse('https://example.com/backup'));
upload.headers.contentType = ContentType('application', 'zstd');
await upload.addStream(filesOf(Directory('data'))
    .transform(tarCodec.encoder)      // Stream<ArchiveFile> -> Stream<List<int>>
    .transform(zstdCodec.encoder));
final response = await upload.close();
```

`zipCodec.encoder` packs the same `Stream<ArchiveFile>` with no second
transform, since zip deflates each entry itself:

```dart
final upload =
    await HttpClient().putUrl(Uri.parse('https://example.com/backup'));
upload.headers.contentType = ContentType('application', 'zip');
await upload.addStream(
    filesOf(Directory('data')).transform(zipCodec.encoder));
final response = await upload.close();
```

The encoders leave an entry open by default, the same as `ZipEncoder.encodeStream`.
`TarCodec(autoClose: true)` and `ZipCodec(autoClose: true)` close each entry once it is
written, and also when the stream is cancelled part way through one.


Both directions also accept a whole buffer, `xzCodec.decode(bytes)` and
`xzCodec.encode(bytes)`. Code that calls `add` itself can use the sinks from
`startChunkedConversion`.

Converters verify the block checks by default, unlike `decodeBytes` and `decodeStream`.
A converter sends decoded data out before the stream ends, so it cannot check that data
again later. `XzCodec(verify: false)` skips the checks and saves about 6% of decode time.

With a sink, `add` or `close` throws on failure, and the rest of the input is not read. The sink you passed in stays open, as it does with
`gzip.decoder` in `dart:io`. If it holds a file or a socket, close it yourself:

```dart
final file = File('out.bin').openWrite();
final sink = xzCodec.decoder.startChunkedConversion(file);
try {
  sink..add(bytes)..close();
} catch (_) {
  await file.close();
  rethrow;
}
```

With a `Stream`, a failure is reported as an error event. The `xzCodec`,
`zstdCodec` and `bzip2Codec` converters then leave the stream open, as
`gzip.decoder` and `gzip.encoder` do. `tarCodec`, `zipCodec` and the threaded
converters close it. Treat the first error as the end either way. `await for`,
`pipe` and `toList` stop there on their own. A `listen` that waits for `onDone`
has to cancel the subscription in `onError`.

## Running a codec off the UI isolate

The converters only look asynchronous. Each piece is processed synchronously to the end.
The table shows how long one call blocks the isolate on the 51 MB `mozilla` file of the
Silesia corpus read with `File.openRead` in 64 KiB pieces, and on the zstd 1.5.7 source
tree for tar, AOT on an Apple M-series. The call that completes a bzip2 block decodes or
sorts the whole block. Memory is the peak RSS above what the process used before the run:

| call | worst single call | 99th percentile | worst with `verify: false` | memory |
| --- | --- | --- | --- | --- |
| `tarCodec.decoder` | 0.2 ms | < 0.1 ms | | 7 MB |
| `tarCodec.encoder` | 0.1 ms | < 0.1 ms | | 11 MB |
| `zipCodec.encoder`, one 51 MB entry | 2.2 ms | 1.9 ms | | 6 MB |
| `zstdCodec.decoder` | 0.6 ms | 0.6 ms | 0.5 ms | 11 MB |
| `ZstdEncoderConverter(level: 3)` | 1.0 ms | 0.8 ms | | 36 MB |
| `ZstdEncoderConverter(level: 19)` | 90 ms | 43 ms | | 147 MB |
| `xzCodec.decoder` | 6.7 ms | 6.0 ms | 5.9 ms | 36 MB |
| `xzCodec.encoder`, LZMA2 chunks stored uncompressed | 0.2 ms | 0.1 ms | | 6 MB |
| `BZip2DecoderConverter()`, 100k blocks | 9.0 ms | 8.6 ms | 8.5 ms | 8 MB |
| `bzip2Codec.decoder`, 900k blocks | 45 ms | 43 ms | 45 ms | 37 MB |
| `BZip2EncoderConverter(blockSize100k: 1)` | 25 ms | 15 ms | | 37 MB |
| `bzip2Codec.encoder`, 900k blocks | 216 ms | 74 ms | | 19 MB |

The zip number is one deflate step. Deflate runs in 64 KiB steps, so an entry is not
held in memory or compressed in one blocking call. On the web the entry is still
deflated in one call, because `Deflate` there processes its whole input at once.

Reading 20000 small tar entries takes 44 ms in total, so a `.tar.zst` costs about the
same as the zstd row. A frame at 60 Hz is 16 ms, so use an isolate for the rows above
16 ms and for large inputs. Run the whole pipeline in the isolate,
so only the file paths are sent to it:

```dart
await Isolate.run(() async {
  final out = File('data.tar').openWrite();
  await File('data.tar.bz2').openRead().transform(bzip2Codec.decoder).pipe(out);
});
```

## Spreading one call over isolates

Two codecs split a single call across isolates: xz decoding and zstd
compression. With the options set, the call returns at once and the result is passed
to `onDone`, since an isolate cannot be waited on synchronously. On dart2js and
dart2wasm, which have no isolates, the same code runs in the calling isolate and
produces the same bytes.

Multithreaded zstd writes the same frame as `zstd -T`. That frame differs from the
single threaded output, but it does not depend on the number of workers. Prefer the
file form. Each worker reads its own job from disk, so the input is never loaded into
the calling isolate. Compressing 1 GB at level 6 this way uses 151 MB of memory,
compared with 2 GB through `encodeBytes`:

```dart
final input = InputFileStream('data.bin');
final output = OutputFileStream('data.bin.zst');
final completer = Completer<bool>();
ZstdEncoder(level: 6).encodeStream(input, output,
    multithread: ZstdMultithreadOptions(
      onDone: completer.complete,
      onError: (error, _) => completer.completeError(error),
      workers: 4,
    ));
await completer.future;
await output.close();
await input.close();
```

xz decoding of a whole buffer sends one block to each worker:

```dart
final completer = Completer<Uint8List>();
XZDecoder().decodeBytes(compressed,
    verify: true,
    throwOnError: true,
    multithread: XZMultithreadOptions(
      onDone: completer.complete,
      onError: (error, _) => completer.completeError(error),
      workers: 4,
    ));
final data = await completer.future;
```

`decodeStream` takes the same options. With an `InputFileStream`, each worker reads its
own block from the file through a read buffer, so the archive is not held in memory.

A zstd `Stream` accepts the options through the codec, and `transform` is used as usual:

```dart
await File('data.bin')
    .openRead()
    .transform(ZstdCodec(
      level: 6,
      multithread: ZstdMultithreadOptions.converter(workers: 4),
    ).encoder)
    .pipe(File('data.bin.zst').openWrite());
```

The stream reports its own end and errors, so `ZstdMultithreadOptions.converter` has no
`onDone`. `startChunkedConversion` throws `ArgumentError` with these options, because a
sink must write its output before `add` returns and a worker finishes later.

`workers` changes only the time, never the output bytes. `memoryBudget` limits how many
workers run at once and defaults to 1 GB. A zstd worker counts its job, its prefix, its
output and the level's tables. An xz worker counts the dictionary size from its block
header and the block itself. At least one worker always runs. xz also has
`fileReadBufferSize`, the buffer a worker uses to read its block when it opens the file
itself.

zstd's `jobSize` and `overlapLog` do change the output bytes, as they do in `zstd -T`.
An invalid value throws `ArgumentError` synchronously from the call, and `onError` is not
called. An input too small to split is compressed on the single threaded path
automatically.

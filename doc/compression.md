# Compression codecs

Each codec compresses or decompresses a single stream of bytes. They all
follow the same shape:

```text
Uint8List encodeBytes(List<int> data, {...});
void      encodeStream(InputStream input, OutputStream output, {...});

Uint8List   decodeBytes(List<int> data, {...});
bool        decodeStream(InputStream input, OutputStream output, {...});
InputStream decodeLazy(InputStream input, {...});
```

`decodeStream` returns `false` when the input is malformed or truncated;
whatever was decoded before the failure is already in `output` and should be
discarded. `decodeLazy` returns a stream that decodes as it is read and
throws `ArchiveException` when it reaches bad data (see
[streaming](streaming.md#decoding-as-you-read-decodelazy)).

`decodeBytes` and `decodeStream` on `GZipDecoder`, `ZLibDecoder`,
`BZip2Decoder`, `ZstdDecoder` and `XZDecoder` take `maxOutputSize`, which
throws `ArchiveException` as soon as the output would pass that many bytes.
See [security](security.md).

## Choosing a codec

| Codec | Notes |
|---|---|
| gzip | `.gz`, `.tar.gz`. Native zlib on the VM. The most widely readable. |
| zlib / deflate | The same compression with a different (or no) header; used inside zip, PNG and many protocols. |
| bzip2 | `.bz2`, `.tar.bz2`. Pure Dart. |
| zstd | `.zst`, `.tar.zst`. Pure Dart, levels from very fast to high ratio. |
| xz | `.xz`, `.tar.xz`. Full decoder; the encoder does not compress. |

## gzip

```dart
final gz = GZipEncoder().encodeBytes(data, level: 9);
final fromGz = GZipDecoder().decodeBytes(gz);
```

- `level`: 0 (store) to 9 (smallest). Default 6.
- `GZipDecoder().decodeBytes` cannot report a truncated input; it returns
  whatever decoded. Use `decodeStream` and check the result when that
  matters, or set `maxOutputSize`, which routes through `decodeStream`.
- `verify`: check the CRC of the output. Not every implementation honours
  it.
- On native platforms this uses `dart:io`'s zlib. See
  [platforms](platforms.md#choosing-the-gzipzlib-implementation) for the
  pure Dart `GZipDecoderWeb`/`GZipEncoderWeb`.

## zlib and raw deflate

```dart
final z = ZLibEncoder().encodeBytes(data);
final fromZ = ZLibDecoder().decodeBytes(z);
```

`ZLibDecoder` takes `raw: true` for deflate data with no zlib header, as
found inside zip files. For encoding raw deflate, use `Deflate`, the pure
Dart encoder:

```dart
final deflated = Deflate(data, level: 6).getBytes(); // raw deflate, no header
final inflated = ZLibDecoder().decodeBytes(deflated, raw: true);
```

`Inflate` is the matching pure Dart decoder (`Inflate(bytes).getBytes()`).
Compression levels are in `DeflateLevel`: `none` (0), `bestSpeed` (1),
`defaultCompression` (6), `bestCompression` (9).

## bzip2

```dart
final bz = BZip2Encoder().encodeBytes(data);
final fromBz = BZip2Decoder().decodeBytes(bz, verify: true);
```

- The encoder always uses 900 KB blocks (`bzip2 -9`); it has no level.
- `verify` checks the block CRCs.
- Only the first stream is decoded. Files made by concatenating bzip2
  streams, as parallel tools such as `pbzip2` write, decode to just the
  first part, without an error.

## zstd

```dart
final zst = ZstdEncoder().encodeBytes(data, level: 19, checksum: true);
final fromZst =
    ZstdDecoder().decodeBytes(zst, verify: true, throwOnError: true);
```

`ZstdEncoder`:

- `level`: `zstdMinLevel` (-7, fastest) to `zstdMaxLevel` (22, smallest).
  0 means `zstdDefaultLevel` (3). Levels 20 and up use windows of 32 MB or
  more, which the decoder must also hold.
- `checksum`: append a content checksum (off by default).
- Output is a single frame with the content size in its header.
- No dictionary support when encoding.

`ZstdDecoder`:

- `ZstdDecoder(dictionary: bytes)` decodes frames made with a dictionary,
  either a `zstd --train` dictionary or raw content bytes.
- `ZstdDecoder(maxWindowSize: ...)` is the largest window a frame may ask
  for, default `zstdDefaultMaxWindowSize` (128 MB), up to 2 GB. Raise it
  for files written with `zstd --long` or `--ultra`.
- `verify` checks frame checksums where present.
- `throwOnError` makes `decodeBytes`/`decodeStream` throw
  `ArchiveException` on bad input instead of returning partial output or
  `false`.
- Multiple frames are decoded in sequence; skippable frames are ignored.

```dart
final decoder = ZstdDecoder(
    dictionary: dictionary, maxWindowSize: 256 * 1024 * 1024);
```

## xz

```dart
final xz = XZEncoder().encodeBytes(data);
final fromXz = XZDecoder().decodeBytes(xz, verify: true, throwOnError: true);
```

`XZEncoder` writes valid `.xz` files, but stores the data without
compressing it, and reads all of its input into memory. Use it only where
a tool requires the `.xz` format. `check:` selects the integrity check:
`XZCheck.crc64` (default), `crc32`, `sha256` or `none`. On dart2js use
`crc32`; see [platforms](platforms.md).

`XZDecoder` reads `.xz` files with LZMA2 compression, optionally behind the
x86 BCJ filter (the filter chains `xz` itself produces by default and with
`--x86`). Other filters fail with an error. Legacy `.lzma` files are not
supported. Options:

- `verify`: check each block's CRC-32 or CRC-64 (CRC-64 not on dart2js).
  SHA-256 checks are read but not verified.
- `throwOnError`: throw `ArchiveException` on bad input instead of
  returning partial output or `false`.
- `XZDecoder(maxDictionarySize: ...)`: the largest LZMA2 dictionary a block
  may declare, default 256 MB. This bounds the memory a decode takes.
- `XZDecoder(maxPreallocateSize: ...)`: the most output it will allocate up
  front because the archive's index says so. Default
  `xzDefaultMaxPreallocateSize` (2 GB native, 256 MB web). Larger outputs
  still decode; the buffer grows as data arrives.
- `uncompressedSize(bytes)` reads the size from the index without decoding.

```dart
final input = InputFileStream('big.log.xz');
final output = OutputFileStream('big.log');
final ok = XZDecoder().decodeStream(input, output, verify: true);
await input.close();
await output.close();
```

### Multithreaded xz decoding

An `.xz` written in several blocks (`xz -T0`, or `xz --block-size=...`) can
be decoded on several isolates. Pass `XZMultithreadOptions`; the call then
returns immediately (an empty list or `false`) and the result arrives through
`onDone`:

```dart
final input = InputFileStream('big.log.xz');
final output = OutputFileStream('big.log');
final done = Completer<bool>();
XZDecoder().decodeStream(input, output,
    multithread: XZMultithreadOptions(
      onDone: done.complete,
      onError: (e, s) => done.completeError(e, s),
      workers: 4,
      memoryBudget: 512 * 1024 * 1024,
    ));
final ok = await done.future;
await input.close();
await output.close();
```

- `workers`: maximum isolates. Default is one less than the number of
  processors.
- `memoryBudget`: cap on memory held by workers, default 1 GB
  (`xzDefaultMemoryBudget`). It can lower the worker count.
- `fileReadBufferSize`: read buffer for each worker when the input is an
  `InputFileStream` (default 8 MB).
- `onError` is required if you set `throwOnError`.

`decodeStream` from an `InputFileStream` to an `OutputFileStream` is the
cheapest combination: each worker reads its own block from the file. With
`decodeBytes`, the input, output and a copy of each block in flight are all
in memory. A single-block file is decoded on one isolate. On the web there
are no isolates; the decode runs on the calling thread and still reports
through `onDone`.

## Checksums

`getCrc32(bytes)`, `getAdler32(bytes)` and `getCrc64(bytes)` are exported
for your own use. Each takes an optional running value to continue a
checksum across chunks. `getCrc64` is not available on dart2js.

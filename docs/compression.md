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

Without flags, `decodeBytes` returns what decoded before the damage and
`decodeStream` returns `false` when the input is malformed or truncated;
whatever was decoded before the failure is already in `output` and should be
discarded. `throwOnError: true` throws `ArchiveException` instead.
`verify: true` also checks the checksums: alone it reports a mismatch the same
way as damage, and with `throwOnError: true` a mismatch throws
`ArchiveChecksumException` (see [errors](README.md#errors)).
`decodeLazy` returns a stream that decodes as it is read and
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
| zstd | `.zst`, `.tar.zst`. Pure Dart port of zstd 1.5.7, levels from very fast to high ratio. |
| xz | `.xz`, `.tar.xz`. Full decoder; the encoder does not compress. |

## gzip

```dart
final gz = GZipEncoder().encodeBytes(data, level: 9);
final fromGz = GZipDecoder().decodeBytes(gz);
```

- `level`: 0 (store) to 9 (smallest). Default 6.
- Without flags `GZipDecoder().decodeBytes` returns whatever decoded from a
  truncated input. Pass `throwOnError: true` when that matters.
- `verify`: check the CRC and size of every member.
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
- Concatenated streams, as parallel tools such as `pbzip2` write, are
  decoded in sequence, as `bzip2 -d` does.

## zstd

```dart
final zst = ZstdEncoder().encodeBytes(data, level: 19);
final fromZst =
    ZstdDecoder().decodeBytes(zst, verify: true, throwOnError: true);
```

The encoder and decoder are ported from zstd 1.5.7, and the encoder output
is byte identical with the reference at every level.

`ZstdEncoder`:

- `level`: `zstdMinLevel` (-131072, fastest) to `zstdMaxLevel` (22,
  smallest). Negative levels are `zstd --fast=N`. 0 means `zstdDefaultLevel`
  (3), and a level outside the range is treated as the nearest end. Levels
  20 and up use windows of 32 MB or more, which the decoder must also hold.
- `checksum`: append a content checksum (off by default).
- `dictionary`: the dictionary bytes, see below. `ZstdEncoder.withDictionary`
  takes a `ZstdDictionary` parsed once.
- Output is a single frame.
- `multithread` splits the work over isolates, see
  [streams and isolates](streams-and-isolates.md#spreading-one-call-over-isolates).

`ZstdDecoder`:

- `ZstdDecoder(dictionary: ...)` decodes frames made with a dictionary,
  either a `zstd --train` dictionary or raw content bytes.
  `ZstdDecoder.withDictionary` takes a `ZstdDictionary` parsed once.
- `ZstdDecoder(maxWindowSize: ...)` is the largest window a frame may ask
  for, default `zstdDefaultMaxWindowSize` (128 MB). Raise it for files
  written with `zstd --long` or `--ultra`.
- `verify` checks frame checksums where present.
- `throwOnError` makes `decodeBytes`/`decodeStream` throw
  `ArchiveException` on bad input instead of returning partial output or
  `false`.
- Multiple frames are decoded in sequence; skippable frames are ignored.

```dart
final decoder = ZstdDecoder(
    dictionary: dictionary, maxWindowSize: 256 * 1024 * 1024);
```

A dictionary trained with `zstd --train` is passed to both the encoder and the decoder.
The frame header stores the dictionary ID, so the frame can only be decoded with the same
dictionary:

```dart
final dictionary = File('dict').readAsBytesSync();
final compressed =
    ZstdEncoder(level: 6, dictionary: dictionary).encodeBytes(bytes);
final data = ZstdDecoder(dictionary: dictionary).decodeBytes(compressed);

// ZstdDictionary is parsed once, so encoders and decoders can share it
final parsed = ZstdDictionary(dictionary);
final again = ZstdDecoder.withDictionary(parsed).decodeBytes(compressed);
```

Unlike original zstd CLI, compression levels 20-22 do not require --ultra flag
to work in `ZstdEncoder`, which knows the input size. `ZstdEncoderConverter`
and `ZstdCodec` without `contentSize` reduce them to 19 unless `ultra: true` is
given, as `zstd` does without `--ultra`: level 22 of unknown size takes 655 MB
even for 100 bytes of input.

## xz

```dart
final xz = XZEncoder().encodeBytes(data);
final fromXz = XZDecoder().decodeBytes(xz, verify: true, throwOnError: true);
```

`XZEncoder` writes valid `.xz` files, but stores the data without
compressing it. Use it only where
a tool requires the `.xz` format. `check:` selects the integrity check:
`XZCheck.crc64` (default), `crc32`, `sha256` or `none`.

`XZDecoder` reads `.xz` files with LZMA2 compression, optionally behind the
x86 BCJ filter (the filter chains `xz` itself produces by default and with
`--x86`). Other filters fail with an error. Legacy `.lzma` files are not
supported. Options:

- `verify`: check each block's CRC-32 or CRC-64.
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
- Without `onError` a failure reaches `onDone` as empty output.

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

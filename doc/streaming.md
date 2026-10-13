# Memory and streaming

Every encoder and decoder has two forms:

- `decodeBytes` / `encodeBytes` take and return bytes. Simple, and the
  whole input and output are in memory.
- `decodeStream` / `encodeStream` read from an `InputStream` and, for
  codecs, write to an `OutputStream`. With file streams, data moves through
  a small buffer and the file is never held whole.

The compression decoders have a third, `decodeLazy`, which returns a stream
that decompresses as it is read.

## Stream classes

| Class | Reads/writes | Notes |
|---|---|---|
| `InputMemoryStream` | a `List<int>` / `Uint8List` | Random access. No copy is made of a `Uint8List`. |
| `OutputMemoryStream` | a growing buffer | `getBytes()` returns the result. Pass `size:` to pre-size it. |
| `InputFileStream` | a file, through a read buffer | Random access. `bufferSize:` sets the buffer. Native only. |
| `OutputFileStream` | a file, through a write buffer (1 MB default) | Creates parent directories. Call `close()`/`closeSync()`. Native only. |
| `InputDecodeStream` | decompressed data, produced on demand | Forward-only. Returned by `decodeLazy`. |

`InputStream` and `OutputStream` are the abstract base classes; any decoder
that takes one accepts any of the implementations.

Close file streams when you are done (`await stream.close()` or
`stream.closeSync()`). `OutputFileStream` only writes its last buffer on
close or `flush()`.

## In memory

```dart
final bytes = File('example.zip').readAsBytesSync();
final archive = ZipDecoder().decodeBytes(bytes);
```

This is the only option on the web and is fine for anything that fits
comfortably in memory.

## From and to files

```dart
// A zip read from disk, each entry decompressed straight into a file.
final input = InputFileStream('example.zip');
final archive = ZipDecoder().decodeStream(input);
for (final file in archive) {
  if (!file.isFile) continue;
  // Check file.name before using it as a path: see security.md.
  final output = OutputFileStream('out/${file.name}');
  file.writeContent(output); // decompresses into the file
  await output.close();
}
await input.close();
```

```dart
// Compress a file of any size to a file.
final input = InputFileStream('big.log');
final output = OutputFileStream('big.log.gz');
GZipEncoder().encodeStream(input, output);
await input.close();
await output.close();
```

Streams can be mixed. To decompress a file into memory:

```dart
final output = OutputMemoryStream();
final ok = GZipDecoder().decodeStream(InputFileStream('data.gz'), output);
if (!ok) throw const FormatException('Truncated or corrupt gzip');
final bytes = output.getBytes();
```

## How entry content is loaded

Decoding an archive reads its directory, not its data. Each `ArchiveFile`
points at its compressed content (in memory, or at an offset in an
`InputFileStream`) and decompresses it only when asked:

| Call | Effect |
|---|---|
| `file.size` | Uncompressed size from the archive. No decoding. |
| `file.writeContent(output)` | Decompresses into `output` without keeping a copy. Best for large entries. |
| `file.readBytes()` | Decompresses into memory and caches it on the entry; returns `Uint8List?`. |
| `file.getContent()` | Same, as an `InputStream?`. |
| `file.content` | Same as `readBytes()`, returning an empty list instead of `null`. |
| `file.rawContent` | The stored (compressed) data, as a `FileContent`. |
| `file.closeSync()` / `await file.close()` | Frees cached data and closes the underlying file handle. |
| `archive.clearSync()` / `await archive.clear()` | Does that for every entry and empties the archive. |

When an archive was decoded from an `InputFileStream`, the entries read from
that file lazily, so keep the stream open until you have read what you need.

Zip needs random access: the decoder reads the central directory at the end
of the file first. Use `decodeBytes` or an `InputFileStream`, not a
forward-only stream. Tar is read front to back.

## Decoding as you read: decodeLazy

`GZipDecoder`, `ZLibDecoder`, `BZip2Decoder`, `XZDecoder` and `ZstdDecoder`
have `decodeLazy(input)`, which returns an `InputStream` that decompresses
only as far as it is read and keeps only a window of the output in memory.
Chaining it into `TarDecoder` reads a `.tar.gz` of any size in one pass, with
no temp file and no full copy in memory:

```dart
final file = InputFileStream('backup.tar.gz');
final tar = GZipDecoder().decodeLazy(file);
TarDecoder().decodeStream(tar, keepEntries: false, callback: (entry) {
  if (entry.isFile && !entry.isSymbolicLink) {
    // Check entry.name before using it as a path: see security.md.
    final output = OutputFileStream('restored/${entry.name}');
    entry.writeContent(output);
    output.closeSync();
  }
});
await tar.close();
await file.close();
```

The stream is forward-only. Each entry's content can be read until the
decoder moves past it, which is why the work happens in `callback`. Once the
decoded window has moved on, reading an earlier entry throws an
`ArchiveException`, so don't keep entries to read after `decodeStream`
returns. `keepEntries: false` tells the decoder not to collect them either:
entries go only to `callback`, the returned `Archive` is empty, and memory
stays flat however many entries the tar has.
`extractFileToDisk` does exactly this for `.tar.gz`, `.tar.bz2`, `.tar.xz`
and `.tar.zst`.

To list a large compressed tar without reading the file data, pass
`storeData: false`. The `ArchiveFile` sizes are then 0; the headers in
`TarDecoder.files` have them:

```dart
final file = InputFileStream('example.tar.zst');
final tar = ZstdDecoder().decodeLazy(file);
final decoder = TarDecoder();
decoder.decodeStream(tar, storeData: false);
for (final header in decoder.files) {
  print('${header.filename}  ${header.fileSize}');
}
await file.close();
```

Other notes on `InputDecodeStream`:

- `length` on the top-level stream has to decode everything to count it.
  Loop on `isEOS` instead.
- A malformed or truncated input throws `ArchiveException` from the read
  that reaches the bad data, not up front.
- An xz block that uses the x86 BCJ filter is decoded whole before any of it
  can be read.

## Memory at a glance

| Approach | Peak memory |
|---|---|
| `decodeBytes` | input + output |
| `decodeStream`, memory input, file output | input + codec state |
| `decodeStream`, file to file | codec state and buffers only |
| `decodeLazy` into `TarDecoder` with `callback` | codec state and a window of output |
| `ArchiveFile.readBytes()` | the whole entry, cached until `close`/`clear` |
| `ArchiveFile.writeContent(fileStream)` | codec state and buffers only |

"Codec state" is small for gzip and zlib, and a few MB for bzip2. For xz
it is the LZMA2 dictionary the file was written with (8 MB for xz's default
preset, at most `maxDictionarySize`). For zstd it is the frame's window (up
to `maxWindowSize`, 128 MB by default).

Encoders: `ZipEncoder` streams each new entry from its source through the
compressor into the output. `TarEncoder` copies stream-backed entries in
chunks. `GZipEncoder`, `ZLibEncoder` and `BZip2Encoder` work in chunks or
blocks, and `ZstdEncoder` in a sliding window that grows with the level.
`XZEncoder` reads its whole input into memory.

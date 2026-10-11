# Untrusted input

An archive from a user, a download or another system can be built to harm
the program reading it: a few kilobytes that expand to gigabytes, sizes and
headers that claim huge allocations, or paths that point outside the
directory you extract into. The package has limits for each of these, but
most are off unless you set them.

## Checklist

1. **Set an output limit** on every decode: `maxOutputSize` for codecs,
   `maxSize` for the extraction helpers.
2. **Check `ArchiveFile.size`** before reading a zip or tar entry, and skip
   or reject entries that are too large.
3. **Extract with `extractFileToDisk` or `extractArchiveToDisk`**, which
   keep files and links inside the output directory. If you write entries
   yourself, check every path (below).
4. **Keep the default memory caps** (`ZstdDecoder.maxWindowSize`,
   `XZDecoder.maxDictionarySize`) unless you trust the source, and lower
   them on memory-constrained devices.
5. **Catch errors.** Malformed data is reported as `ArchiveException` (a
   `FormatException`). Where a codec's `decodeStream` returns `false`, or
   `throwOnError` is available, treat a failed decode as a failure and
   discard the output.
6. **Limit the entry count** if that matters to you: nothing in the package
   caps how many entries an archive has. For tar, count in the `callback`
   and pass `keepEntries: false` so entries are not collected in memory.
7. **Decode off the UI thread** in Flutter apps (for example with
   `Isolate.run`) so a slow or hostile archive cannot freeze the app.

## Output limits

`decodeBytes` and `decodeStream` on `GZipDecoder`, `ZLibDecoder`,
`BZip2Decoder`, `ZstdDecoder` and `XZDecoder` take `maxOutputSize`. The
decode throws `ArchiveException` as soon as the output would pass it, before
the excess is written.

```dart
try {
  GZipDecoder().decodeBytes(bomb, maxOutputSize: 1024 * 1024);
} on ArchiveException catch (e) {
  print('refused: ${e.message}');
}
```

`decodeLazy`, the `*Web` codec classes, `Inflate` and `LzmaDecoder` have no
such parameter. When `decodeLazy` feeds a `TarDecoder`, check each entry's
size in the callback, or use `extractFileToDisk` with `maxSize`.

## Memory limits

| Setting | Default | Bounds |
|---|---|---|
| `ZstdDecoder(maxWindowSize:)` | 128 MB | The history window a frame may ask for. |
| `XZDecoder(maxDictionarySize:)` | 256 MB | The LZMA2 dictionary a block may declare. |
| `XZDecoder(maxPreallocateSize:)` | 2 GB native, 256 MB web | What is allocated up front because the file claims it. Larger outputs still decode. |
| `XZMultithreadOptions(memoryBudget:)` | 1 GB | Memory held by xz worker isolates. |
| `TarFile.maxMetadataSize` | 1 MB (constant) | GNU long name and pax header entries. Larger ones throw. |

```dart
final xz = XZDecoder(maxDictionarySize: 64 * 1024 * 1024);
final zstd = ZstdDecoder(maxWindowSize: 8 * 1024 * 1024);
```

The xz and zstd decoders do not trust sizes written in headers when
allocating: they pre-size only up to what the input could plausibly decode
to, and otherwise grow buffers as data arrives. A zip entry read with
`readBytes()` or `getContent()` pre-sizes its buffer from the declared size
only as far as its compressed data could expand to, and up to 500 MB.

## Entry sizes

`ArchiveFile.size` is the uncompressed size the archive declares. You can
rely on it as an upper bound before reading:

- A zip entry is never decoded past its declared size. If the compressed
  data expands further, reading throws `ArchiveException`.
- A tar entry's content is exactly the number of bytes its header gives.

```dart
final input = InputFileStream('upload.zip');
final archive = ZipDecoder().decodeStream(input);
for (final entry in archive) {
  if (entry.isFile && entry.size > maxEntrySize) {
    throw ArchiveException('${entry.name} is too large');
  }
}
```

The size check does not cover the archive's own structure: a zip's central
directory or a long list of tar headers is read in full by `decodeBytes` and
`decodeStream`.

## Extracting safely

`extractFileToDisk`, `extractArchiveToDisk` and `extractArchiveToDiskSync`:

- skip entries whose normalized path is outside the output directory
  (`../`, absolute paths);
- skip symbolic links whose target is absolute or resolves outside the
  output directory;
- create links only after all files are written, and refuse a link whose
  path or target runs through another link, so an entry cannot be written
  through a link the archive made;
- take `maxSize`, the total bytes the extracted files may come to. An
  entry that would pass it throws `ArchiveException` before it is written.

```dart
await extractFileToDisk('upload.tar.gz', 'out', maxSize: 500 * 1024 * 1024);
```

Skipped entries are skipped silently. If an entry fails to decode, the
helper throws and removes that entry's partial file; files already written
stay.

### Writing entries yourself

Entry names come from the archive and can contain `..`, absolute paths, or
drive letters. Resolve each one against the output directory and check it
stays inside, using `package:path`:

```dart
final outDir = p.canonicalize('safe_out');
for (final entry in archive) {
  final target = p.canonicalize(p.join(outDir, entry.name));
  if (!p.isWithin(outDir, target)) {
    continue; // skip "../" and absolute paths
  }
  if (entry.isFile && !entry.isSymbolicLink) {
    final output = OutputFileStream(target);
    entry.writeContent(output);
    await output.close();
  }
}
```

`isFile` is also true for symbolic links, hence the extra check. Handle
links separately: either skip them, or check that the target stays inside
the output directory and create them only after everything else is written.

## Encryption

Zip passwords protect content, not names or sizes, which are readable
without the password. Traditional ZipCrypto encryption is weak; archives
written by this package use AES-256.

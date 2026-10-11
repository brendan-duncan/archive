# Reading archives

Archive decoders return an `Archive`: an iterable of `ArchiveFile` entries,
with `find(name)` for lookup by path. Entry content is decompressed only when
you read it (see [streaming](streaming.md#how-entry-content-is-loaded)).

For archives from outside your control, read [security](security.md) too.

## Entries

Useful `ArchiveFile` members when reading:

| Member | Meaning |
|---|---|
| `name` | Path inside the archive, with `/` separators. Directories usually end in `/`. |
| `size` | Uncompressed size given by the archive. |
| `isFile`, `isDirectory` | Entry kind. |
| `isSymbolicLink`, `symbolicLink` | Whether it is a link, and its target. |
| `mode`, `unixPermissions` | Unix mode bits, when the archive stores them. |
| `lastModTime` | Modification time. For tar this is seconds since the epoch; for zip it is the packed DOS date and time, which `lastModDateTime` decodes. |
| `crc32` | CRC-32 stored in a zip. |
| `compression` | For zip: how the entry is stored (`CompressionType.deflate`, `bzip2`, `zstd` or `none`). |
| `readBytes()`, `writeContent(output)`, `getContent()` | Read the content. |

## Zip

```dart
final input = InputFileStream('example.zip');
final archive = ZipDecoder().decodeStream(input);
for (final entry in archive) {
  print('${entry.name} ${entry.size} '
      '${entry.isFile ? 'file' : 'dir'} ${entry.compression}');
}
final readme = archive.find('readme.txt');
if (readme != null) {
  print(utf8.decode(readme.readBytes()!));
}
await input.close();
```

Use `ZipDecoder().decodeBytes(bytes)` when the zip is already in memory.
Both forms take an optional `callback`, called with each entry as the
directory is read, and `password`.

Entries may be stored, deflated, bzip2 or zstd compressed. Zip64 archives
(over 4 GB, or over 65,535 entries) are read automatically.

### Checking integrity

The zip decoder does not check CRCs as it reads (its `verify` parameter is
currently ignored). To check an entry, use the `ZipFile` behind it, which
decompresses without keeping the data:

```dart
for (final entry in archive) {
  final raw = entry.rawContent;
  if (raw is ZipFile && !raw.verifyCrc32()) {
    print('${entry.name} is damaged');
  }
}
```

### Encrypted zips

Pass the password to the decoder. Both traditional PKWARE encryption
("ZipCrypto") and WinZip AES (128, 192 and 256 bit) are supported.

```dart
final input = InputFileStream('secret.zip');
final archive = ZipDecoder().decodeStream(input, password: 'secret');
try {
  final bytes = archive.find('readme.txt')!.readBytes();
} on ArchiveException catch (e) {
  print('Could not decrypt: $e');
}
await input.close();
```

Decryption happens as content is read, so a wrong password is reported when
you read an entry, not by `decodeStream`. Reading an encrypted entry with no
password also throws `ArchiveException`.

## Tar

```dart
final archive = TarDecoder().decodeStream(InputFileStream('example.tar'),
    verify: true);
for (final entry in archive) {
  if (entry.isSymbolicLink) {
    print('${entry.name} -> ${entry.symbolicLink}');
  }
}
```

`TarDecoder` reads ustar and GNU tar, including GNU long names and links, and
these pax header fields: `path`, `linkpath`, `size` (files of 8 GB and up),
`mtime`, `uid` and `gid`. Other pax fields are ignored.

Options:

- `verify: true` checks each header's checksum and throws `ArchiveException`
  on a mismatch. Without it, a file that is not a tar can decode as garbage
  entries; use it when you are not sure the input is a tar.
- `storeData: false` skips file contents, for listing. The headers, with
  sizes, are in `decoder.files` afterwards.
- `callback` is called with each entry as it is read. With a
  [`decodeLazy`](streaming.md#decoding-as-you-read-decodelazy) input this
  is the only time the content can be read.
- `keepEntries: false` passes entries only to `callback`; the returned
  `Archive` and `decoder.files` stay empty, so memory does not grow with the
  number of entries.
- `TarDecoder(filenameEncoding: ...)` for names that are not UTF-8.

Hard links are returned as symbolic links to the same target.

For `.tar.gz` and the other compressed tars, decompress first:
`TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes))` in memory, or
`decodeLazy` for files.

## Symbolic links

Zip entries written on Unix with a link file type, and tar symlink entries,
have `isSymbolicLink` set and the target in `symbolicLink`. Nothing is
created on disk until you extract. If you create links yourself, create them
after all other entries, and check that the target stays inside your output
directory; `extractFileToDisk` and `extractArchiveToDisk` do both.

## Extracting to disk (native)

`archive_io.dart` has three helpers.

`extractFileToDisk(inputPath, outputPath)` picks the format from the file
extension: `.zip`, `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz`,
`.tar.xz`/`.txz` or `.tar.zst`/`.tzst`. Compressed tars are decompressed and
written in a single pass with no temp file.

```dart
await extractFileToDisk('backup.tar.gz', 'extracted');
await extractFileToDisk('secret.zip', 'extracted_zip', password: 'secret');
```

`extractArchiveToDisk` and `extractArchiveToDiskSync` write an `Archive` you
already decoded:

```dart
final input = InputFileStream('example.zip');
final archive = ZipDecoder().decodeStream(input);
await extractArchiveToDisk(archive, 'extracted2');
// or, synchronously:
extractArchiveToDiskSync(archive, 'extracted3');
await input.close();
```

All three:

- skip entries whose path, or link target, would land outside the output
  directory;
- create symbolic links after everything else;
- take `maxSize`, a limit on the total bytes written (see
  [security](security.md));
- take `bufferSize`, the write buffer per file;
- throw if an entry's content fails to decode, removing the partial file.

`extractFileToDisk` also takes `password` and `callback`, and sets Unix
permissions from the archive on macOS, Linux and Android.

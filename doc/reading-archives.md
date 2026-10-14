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
| `lastModTime` | Modification time in seconds since the epoch, for tar and zip. |
| `crc32` | CRC-32 stored in a zip. |
| `compression` | For zip: how the entry is stored (`CompressionType.deflate`, `bzip2`, `zstd`, `lzma`, `xz` or `none`). |
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

Entries may be stored, deflated, bzip2, zstd, lzma or xz compressed. Zip64
archives (over 4 GB, or over 65,535 entries) are read automatically.

### Checking integrity

`ZipDecoder().decodeStream(input, verify: true)` checks
the CRC-32 of each entry when its content is read and throws
`ArchiveChecksumException` on a mismatch. With `throwOnError: false` as well
a mismatched entry gives no error. To check an entry without keeping the data, use the `ZipFile`
behind it:

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
try {
  final archive =
      ZipDecoder().decodeStream(input, password: 'secret', verify: true);
  final bytes = archive.find('readme.txt')!.readBytes();
} on ArchivePasswordException catch (e) {
  print('Wrong or missing password: $e');
} on ArchiveException catch (e) {
  print('Could not decrypt: $e');
}
await input.close();
```

A wrong or missing password throws `ArchivePasswordException` from
`decodeStream` and `decodeBytes`, whatever the flags. Content is decrypted as
it is read, so `writeContent` does not hold a second copy of a large entry.
An AES entry that does not match its MAC throws `ArchiveMacException` at the
end of the read, whatever the flags.
The check bytes in the header can pass a wrong password, see
[security](security.md#encryption).

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
`mtime`, `uid`, `gid` and the `GNU.sparse` fields. Other pax fields are
ignored. GNU and pax sparse files are expanded.

Options:

- `verify: true` checks each header's checksum and throws `ArchiveException`
  at a mismatch, or stops there with `throwOnError: false`. Without it, a
  file that is not a tar can decode as garbage entries; use it when you are
  not sure the input is a tar.
- `storeData: false` skips file contents, for listing. The headers, with
  sizes, are in `decoder.files` afterwards.
- `callback` is called with each entry as it is read. With a
  [`decodeLazy`](streaming.md#decoding-as-you-read-decodelazy) input this
  is the only time the content can be read.
- `keepEntries: false` passes entries only to `callback`; the returned
  `Archive` and `decoder.files` stay empty, so memory does not grow with the
  number of entries.
- `TarDecoder(filenameEncoding: ...)` for names that are not UTF-8.

A hard link is returned as a symbolic link with its target relative to the
archive root and `isHardLink` set, so after extraction the link points to
its target.

For `.tar.gz` and the other compressed tars, decompress first:
`TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes))` in memory, or
`decodeLazy` for files.

## Recognizing a format from its first bytes

`CodecsRecognizer` detects the format from the header without decoding anything:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

final head = await File('data.bin').openRead(0, CodecsRecognizer.headerBytes)
    .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));

switch (CodecsRecognizer.recognize(head)) {
  case ArchiveFormat.zstd:
    print('zstd');
  case ArchiveFormat.xz:
    print('xz');
  default:
    // ArchiveFormat.unknown
}
```

Each format also has its own check: `isGZip`, `isZLib`, `isBZip2`, `isXZ`,
`isZstd`, `isZip`, `isTar`.

The number of bytes needed depends on the format. A check can answer after 2 bytes for
zlib, 3 for gzip, 4 for bzip2, zstd and zip, and 6 for xz. zlib is checked only when
`withZLib` is true. It is false by default because the zlib check can give false
positives. With more bytes, a check also rejects reserved flag bits and invalid fields:
7 bytes for zlib, 4 for gzip, 5 for zstd, 10 for bzip2 and 12 for xz. With fewer bytes,
a check skips the fields it has not reached, so it can accept data that a full header
would reject. Only tar needs more. A tar header from before ustar has no magic and is
identified by the checksum over the whole 512-byte block. 263 bytes are enough for a
ustar tar, and `CodecsRecognizer.headerBytes` is enough for every format.

Formats without a header, such as raw LZMA and raw deflate, cannot be recognized this
way.

## Symbolic links

Zip entries written on Unix with a link file type, and tar symlink entries,
have `isSymbolicLink` set and the target in `symbolicLink`. Nothing is
created on disk until you extract. If you create links yourself, create them
after all other entries, and check that the target stays inside your output
directory; `extractFileToDisk` and `extractArchiveToDisk` do both.

## Extracting to disk (native)

`archive_io.dart` has three helpers.

`extractFileToDisk(inputPath, outputPath)` reads the type of archive from its
header, or from the file extension when the header is not recognized: `.zip`,
`.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz`, `.tar.xz`/`.txz` or
`.tar.zst`/`.tzst`. Compressed tars are decompressed and written in a single
pass with no temp file.

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

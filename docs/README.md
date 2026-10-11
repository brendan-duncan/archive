# archive documentation

`package:archive` reads and writes archive and compression formats in pure
Dart. It runs on the Dart VM, Flutter, and the web (dart2js and dart2wasm).

| Page | What it covers |
|---|---|
| [Platforms](platforms.md) | Native vs JavaScript vs WebAssembly: what is available, which code runs, limits |
| [Memory and streaming](streaming.md) | Bytes in memory vs file streams, `decodeLazy`, how entry content is loaded |
| [Reading archives](reading-archives.md) | Zip and tar decoding, encrypted zips, symlinks, extracting to disk |
| [Creating archives](creating-archives.md) | Building an `Archive`, zip and tar encoding, zipping and tarring directories |
| [Compression codecs](compression.md) | gzip, zlib/deflate, bzip2, xz, zstd: options and usage |
| [Untrusted input](security.md) | Size limits, path checks, and a checklist for archives you did not create |
| [Migrating 3.x to 4.x](../doc/migrating_3_to_4.md) | Renamed classes and the 4.0 content model |

## Archives and compression

The package has two layers, and most real formats use both.

**Archive formats** hold many files: names, directories, permissions,
timestamps, links. They decode to an `Archive`, a list of `ArchiveFile`
entries, and encode from one.

| Format | Decoder | Encoder |
|---|---|---|
| Zip | `ZipDecoder` | `ZipEncoder`, `ZipFileEncoder` (native) |
| Tar | `TarDecoder` | `TarEncoder`, `TarFileEncoder` (native) |

**Compression codecs** turn one stream of bytes into another. They know
nothing about files.

| Format | Decoder | Encoder |
|---|---|---|
| gzip (`.gz`) | `GZipDecoder` | `GZipEncoder` |
| zlib / raw deflate | `ZLibDecoder`, `Inflate` | `ZLibEncoder`, `Deflate` |
| bzip2 (`.bz2`) | `BZip2Decoder` | `BZip2Encoder` |
| xz (`.xz`) | `XZDecoder` | `XZEncoder` (stores data uncompressed, see [compression](compression.md#xz)) |
| zstd (`.zst`) | `ZstdDecoder` | `ZstdEncoder` |

Zip compresses each entry itself (deflate by default; bzip2, zstd or no
compression per entry). Tar does not compress at all, so a `.tar.gz`,
`.tar.bz2`, `.tar.xz` or `.tar.zst` is a tar archive passed through a codec:

```dart
// Write: archive -> tar bytes -> gzip bytes.
final tarGz = GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));

// Read: gzip bytes -> tar bytes -> archive.
final restored = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(tarGz));
```

For large files, the same chain can run without holding the tar in memory;
see [`decodeLazy`](streaming.md#decoding-as-you-read-decodelazy).

## The two libraries

**`package:archive/archive.dart`** works on every platform. It exports the
`Archive` model, every encoder and decoder, the stream classes
(`InputMemoryStream`, `OutputMemoryStream`, `InputFileStream`,
`OutputFileStream`, `InputDecodeStream`), checksums (`getCrc32`, `getAdler32`,
`getCrc64`) and `ArchiveException`.

**`package:archive/archive_io.dart`** re-exports all of that and adds helpers
that use `dart:io`, so it can only be imported on native platforms:

- `extractFileToDisk`, `extractArchiveToDisk`, `extractArchiveToDiskSync`
- `ZipFileEncoder`, `TarFileEncoder`
- `createArchiveFromDirectory`
- `listTarFiles`, `extractTarFiles`, `createTarFile` (used by the `tar`
  command below)

Import `archive.dart` in code that must also compile for the web, and
`archive_io.dart` in VM, server, CLI and Flutter mobile/desktop code.

## Quick start

```dart
import 'dart:convert';

import 'package:archive/archive.dart';

void main() {
  // Build an archive in memory.
  final archive = Archive()
    ..add(ArchiveFile.string('hello.txt', 'Hello, world!'))
    ..add(ArchiveFile.bytes('data.bin', [1, 2, 3, 4]));

  // Encode it as a zip.
  final zipBytes = ZipEncoder().encodeBytes(archive);

  // Decode it again.
  final decoded = ZipDecoder().decodeBytes(zipBytes);
  for (final file in decoded) {
    print('${file.name}: ${file.size} bytes');
  }
  final hello = decoded.find('hello.txt')!;
  print(utf8.decode(hello.readBytes()!));
}
```

Compressing a single buffer needs no `Archive`:

```dart
final compressed = ZLibEncoder().encodeBytes(data);
final original = ZLibDecoder().decodeBytes(compressed);
```

## Errors

Problems with the data are reported as `ArchiveException`, which extends
`FormatException`. Some decoders report a truncated or corrupt input through
a `false` return value instead of throwing; see each codec in
[compression](compression.md).

## The `tar` command

The package has a small executable, `bin/tar.dart`:

```sh
dart run archive:tar --list    archive.tar.gz
dart run archive:tar --extract archive.tar.gz out_dir
dart run archive:tar --create  some_dir        # writes some_dir.tar.gz
```

`--list` and `--extract` accept `.tar`, `.tar.gz`/`.tgz`,
`.tar.bz2`/`.tbz`, `.tar.zst`/`.tzst` and `.tar.xz`/`.txz`. `--create`
always writes gzip. The same operations are available as `listTarFiles`,
`extractTarFiles` and `createTarFile` in `archive_io.dart`.

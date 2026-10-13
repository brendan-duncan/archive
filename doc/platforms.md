# Platforms

The package is pure Dart and compiles for the Dart VM (including Flutter on
mobile and desktop), JavaScript (dart2js) and WebAssembly (dart2wasm). The
formats and APIs are the same everywhere; what changes is which
implementation runs, whether there is a file system, and how much memory you
can safely ask for.

| | Native (VM, Flutter) | JavaScript (dart2js) | WebAssembly (dart2wasm) |
|---|---|---|---|
| `archive.dart` | yes | yes | yes |
| `archive_io.dart` | yes | no (needs `dart:io`) | no (needs `dart:io`) |
| gzip / zlib | `dart:io` native zlib | pure Dart | pure Dart |
| `InputFileStream` / `OutputFileStream` on paths | yes | no file system | no file system |
| Multithreaded xz | isolates | runs on the calling thread | runs on the calling thread |
| CRC-64 (`getCrc64`, xz CRC-64 checks) | yes | no | yes |
| Default `XZDecoder.maxPreallocateSize` | 2 GB | 256 MB | 256 MB |

## Native

On the VM, `GZipDecoder`, `GZipEncoder`, `ZLibDecoder` and `ZLibEncoder` use
the zlib built into `dart:io` (`GZipCodec`, `ZLibCodec`). Zip entries
compressed with deflate go through the same code. Everything else (bzip2,
xz, zstd, tar, zip structure, encryption) is pure Dart on every platform.

`archive_io.dart` adds the file system helpers: `extractFileToDisk`,
`extractArchiveToDisk[Sync]`, `ZipFileEncoder`, `TarFileEncoder` and
`createArchiveFromDirectory`. `extractFileToDisk` also applies the stored
Unix permissions on macOS, Linux and Android.

`XZDecoder` can decode a multi-block `.xz` on several isolates; see
[compression](compression.md#multithreaded-xz-decoding).

## Web: JavaScript and WebAssembly

Import `package:archive/archive.dart` only. `archive_io.dart` imports
`dart:io` and will not compile for the web.

gzip and zlib use the package's own Dart implementation (`Inflate` and
`Deflate`), selected automatically. You get the same classes, `GZipDecoder`
and friends, so code does not need to change between platforms.

There is no file system. `InputFileStream` and `OutputFileStream` are still
exported (so shared code compiles), but on the web they are backed by a stub:
reads return no data and writes are dropped. Work with bytes
(`decodeBytes`/`encodeBytes`) or memory streams (`InputMemoryStream`,
`OutputMemoryStream`) instead.

A browser `Uint8List` cannot exceed 2 GB. For larger inputs, `RamFileData`
and `RamFileHandle` keep data as a list of chunks that `InputFileStream` can
read through, for example `InputFileStream.asRamFile(stream, length)` for a
`Stream<Uint8List>` from a file picker. This still holds the whole file in
memory. See `example/large_zip_in_browser.dart`.

Other web differences:

- **Memory.** A failed allocation on dart2js or dart2wasm kills the page
  instead of throwing, so `XZDecoder` trusts at most 256 MB of size claims
  in an archive to pre-size its output (`xzDefaultMaxPreallocateSize`),
  against 2 GB on native. Use `maxOutputSize` (see [security](security.md))
  to fail early on outputs you cannot hold.
- **xz multithreading.** Isolates cannot be spawned on either web target.
  Passing `XZMultithreadOptions` still works: the decode runs on the calling
  thread and the result is delivered through `onDone`, which is called
  before `decodeBytes`/`decodeStream` returns. Code that awaits a
  `Completer` completed from `onDone` works the same on both.
- **CRC-64 on dart2js.** JavaScript numbers cannot hold a 64-bit CRC.
  `getCrc64` throws `UnsupportedError`, `XZEncoder` must be given
  `check: XZCheck.crc32` (or `none`/`sha256`) instead of its default
  `crc64`, and `XZDecoder` skips verifying CRC-64 checks. dart2wasm has
  64-bit integers and supports all of these.
- **Speed.** The LZMA range decoder and the zstd bit reader and hash have
  64-bit versions used on the VM and wasm, and slower 32-bit versions used
  on dart2js.

```dart
// On the web, xz must not use the default CRC-64 check under dart2js.
final xz = XZEncoder().encodeBytes(bytes, check: XZCheck.crc32);
```

## Choosing the gzip/zlib implementation

`GZipDecoder`, `GZipEncoder`, `ZLibDecoder` and `ZLibEncoder` pick the
platform implementation. To use the pure Dart one everywhere, for example to
get identical output on every platform, use the `*Web` classes, which are
exported on all platforms:

```dart
final decoded = const GZipDecoderWeb().decodeBytes(bytes);
final encoded = const GZipEncoderWeb().encodeBytes(decoded, level: 6);
```

`GZipDecoderWeb`, `GZipEncoderWeb`, `ZLibDecoderWeb` and `ZLibEncoderWeb`
take a `raw` flag for headerless deflate data. They do not take
`maxOutputSize`; use `GZipDecoder`/`ZLibDecoder` when you need that limit.

# archive
[![Dart CI](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml/badge.svg)](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml)
[![pub package](https://img.shields.io/pub/v/archive.svg)](https://pub.dev/packages/archive)

## Documentation

* [Overview](doc/README.md): archive formats vs compression codecs, and the two libraries
* [Platforms](doc/platforms.md): native, JavaScript and WebAssembly
* [Memory and streaming](doc/streaming.md): in-memory bytes vs file streams, and `decodeLazy`
* [Reading archives](doc/reading-archives.md): zip, tar, encrypted zips, extracting to disk
* [Creating archives](doc/creating-archives.md): zip and tar encoding, directories
* [Compression codecs](doc/compression.md): gzip, zlib, bzip2, xz, zstd
* [Streams and isolates](doc/streams-and-isolates.md): `Stream` converters, running a codec off the UI isolate, multithreaded xz and zstd
* [Untrusted input](doc/security.md): size limits and safe extraction

## 4.6.0 Update

Decoders, and their wrappers like `extractFileToDisk`, `extractArchiveToDisk`, `extractArchiveToDiskSync` now share one
contract for errors. Without flags they never throw on *damaged* data and return what decoded before the damage. 
`throwOnError: true` throws `ArchiveException` on damaged or cut data. `verify: true` also checks checksums: alone it
reports a mismatch or damage like no flags do, `decodeStream` returns `false` and `decodeBytes` returns what decoded, and
with `throwOnError: true` as well a mismatch throws `ArchiveChecksumException`.

UNCHANGED: errors that are not damaged data keep their type and are thrown regardless of `verify` and `throwOnError`:

| Category | Thrown as | Example |
|---|---|---|
| Invalid parameters | `ArgumentError` | `ZstdDecoder(maxWindowSize: 100)`, below the 1024 byte minimum |
| Size limits: `maxOutputSize`, `maxSize`, `maxWindowSize`, `maxDictionarySize`, `TarFile.maxMetadataSize`, the declared size of a compressed zip entry | `ArchiveLimitException`, a subclass of `ArchiveException` | `GZipDecoder().decodeBytes(bomb, maxOutputSize: 1 << 20)` |
| Passwords and AES MAC | `ArchivePasswordException`, `ArchiveMacException` | `ZipDecoder().decodeBytes(zip, password: 'wrong')` |
| Your callbacks | the exception the callback throws | an exception in `ArchiveCallback` stops extraction, one in `ProgressOutputStream.onProgress` goes to the current zone and work continues |
| System | `FileSystemException`, `OutOfMemoryError` and other platform errors | the disk fills up while `extractFileToDisk` writes |

Converters (`xzCodec`, `zstdCodec`, `bzip2Codec` and `tarCodec`) work like `gzip` and `zlib` from 
`dart:io`, as the format specifications expect: they verify checksums by default and report every error to the stream.
`zipCodec` has only encoder part so there is nothing it can verify.

```dart
try {
  // `verify: true` alone reports a mismatch through the return value only, so pass `throwOnError: true` with it to
  // get `ArchiveChecksumException`. `throwOnError` alone may be used when you don't want to pay for an extra
  // ~5-10% speed decrease, yet still wish to get the basic validation errors, or work with archives that remain
  // valid regardless of their incorrect checksum
  final data = XZDecoder().decodeBytes(bytes, verify: true, throwOnError: true);
  print('${data.length} bytes');
} on ArchiveChecksumException {
  print('the data decoded but does not match its checksum');
} on ArchiveException {
  print('the archive is damaged or cut short');
} catch (error) {
  // Disk full, closed socket, OOM and other exceptions from `UNCHANGED` block are not damage
  // related and keep their type and are still reported as before
  print('could not write the output: $error');
} // `ZipDecoder` may also throw `ArchivePasswordException` (regardless of `throwOnError`), a subclass of
  // `ArchiveException`: catch it above `ArchiveException` to tell them apart. An AES entry that does not match its
  // MAC throws `ArchiveMacException`, a subclass of `ArchiveChecksumException`, regardless of flags as well.
  // A size limit throws `ArchiveLimitException`, a subclass of `ArchiveException`, regardless of flags too.
  //
  // Same example can be used for `decodeStream` and wrappers like `extractFileToDisk`
```

### Migration quick tips:
* Code that relied on a decoder throwing without flags has to pass `throwOnError: true`.
* `verify: true` checks checksums in every decoder. Alone it returns `false` from `decodeStream` and partial data from `decodeBytes`, pass `throwOnError: true` as well to throw.
* A wrong or missing zip password throws `ArchivePasswordException` regardless of flags.
* An AES zip entry that does not match its MAC throws `ArchiveMacException` regardless of flags.
* A size limit, such as `maxOutputSize` or `maxSize`, throws `ArchiveLimitException` regardless of flags.
* `lastModTime` of zip entries is now in seconds since epoch, as in tar, instead of the DOS date and time format.
* `CompressionType` has new values `lzma` and `xz`, so a switch over it needs a case for each of them.
* Classes that implement `InputStream` or `OutputStream` must add `readInto`, `viewBytes`, `writeRange` and
  `reserve`. Classes that extend them need no change.
* `AesDecrypt` is removed, use `AesCtr`: `AesDecrypt(key).decryptCrt(data)` becomes
  `AesCtr(key, Uint8List(16)).process(data)`. Hashes are exported as `Sha1`, `HmacSha1`, `pbkdf2HmacSha1` and `Sha256`.

---

## 4.0 Update

The Archive library was originally written when the web was the primary use of Dart. File IO was less of a concern
and the design was around having everything in memory. As other uses of Dart came about, such as Flutter, a lot
of File IO operations were added to the library, but not in a very clean way.

The design goal for the 4.0 revision of the library is to ensure File IO is a primary focus, while minimizing memory
usage. Memory-only interfaces are still available for web platforms.

#### [Migrating 3.x to 4.x](doc/migrating_3_to_4.md).

### Migration quick tips:
* **decodeBuffer** has been renamed to **decodeStream** in the various decoder classes.
* **InputStream** has been renamed to **InputMemoryStream**.
* **OutputStream** has been renamed to **OutputMemoryStream**.

---

## Overview

A Dart library to encode and decode various archive and compression formats.

The archive library currently supports the following codecs:

- Zip
- Tar (including GNU and PAX sparse files)
- ZLib
- GZip
- BZip2
- XZ (Encoder just stores, does not compress)
- Zstandard (zstd)

---

## Usage

**package:archive/archive.dart**
* Can be used for both web and native applications.

**package:archive/archive_io.dart**
  * Provides some extra utilities for 'dart:io' based applications.


#### Decoding a zip file in memory

```dart
import 'package:archive/archive.dart';
import 'dart:io';
void main() {
  final bytes = File('test.zip').readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final entry in archive) {
    if (entry.isFile) {
      final fileBytes = entry.content;
      File('out/${entry.name}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(fileBytes);
    }
  }
}
```

#### Using InputFileStream and OutputFileStream to extract a zip:
```dart
import 'dart:io';
import 'package:archive/archive.dart';
void main() {
  // Use an InputFileStream to access the zip file without storing it in memory.
  // Note that using InputFileStream will result in an error from the web platform  
  // as there is no file system there.
  final inputStream = InputFileStream('test.zip');
  // Decode the zip from the InputFileStream. The archive will have the contents of the
  // zip, without having stored the data in memory. 
  final archive = ZipDecoder().decodeStream(inputStream);
  final symbolicLinks = <ArchiveFile>[]; // keep a list of the symbolic link entities, if any.
  // For all of the entries in the archive
  for (final file in archive) {
    // You should create symbolic links **after** the rest of the archive has been
    // extracted, otherwise the file being linked might not exist yet.
    if (file.isSymbolicLink) {
      symbolicLinks.add(file);
      continue;
    }
    if (file.isFile) {
      // Write the file content to a directory called 'out'.
      // In practice, you should make sure file.name doesn't include '..' paths
      // that would put it outside of the extraction directory.
      // An OutputFileStream will write the data to disk.
      final outputStream = OutputFileStream('out/${file.name}');
      // The writeContent method will decompress the file content directly to disk without
      // storing the decompressed data in memory. 
      file.writeContent(outputStream);
      // Make sure to close the output stream so the File is closed.
      outputStream.closeSync();
    } else {
      // If the entity is a directory, create it. Normally writing a file will create
      // the directories necessary, but sometimes an archive will have an empty directory
      // with no files.
      Directory('out/${file.name}').createSync(recursive: true);
    }
  }
  // Create symbolic links **after** the rest of the archive has been extracted to make sure
  // the file being linked exists.
  for (final entity in symbolicLinks) {
    // Before using this in production code, you should ensure the symbolicLink path
    // points to a file within the archive, otherwise it could be a security issue.
    final link = Link('out/${entity.name}');
    link.createSync(entity.symbolicLink!, recursive: true);
  }
  inputStream.closeSync();
}
```
#### extractFileToDisk
`extractFileToDisk` is a convenience function to extract the contents of
an archive file directory to an output directory.
The type of archive is read from its header, or from the file extension when the header is not recognized.
```dart
import 'package:archive/archive_io.dart';
// ...
await extractFileToDisk('test.zip', 'out');
```
#### extractArchiveToDisk
`extractArchiveToDisk` is a convenience function to write the contents of an Archive
to an output directory.
```dart
import 'package:archive/archive_io.dart';
// ...
// Use an InputFileStream to access the zip file without storing it in memory.
final inputStream = InputFileStream('test.zip');
// Decode the zip from the InputFileStream. The archive will have the contents of the
// zip, without having stored the data in memory. 
final archive = ZipDecoder().decodeStream(inputStream);
await extractArchiveToDisk(archive, 'out');
await inputStream.close();
```

# archive
[![Dart CI](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml/badge.svg)](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml)
[![pub package](https://img.shields.io/pub/v/archive.svg)](https://pub.dev/packages/archive)

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
- Tar
- ZLib
- GZip
- BZip2
- XZ

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
      final fileBytes = file.readBytes();
      File('out/${file.fullPathName}')
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
  final symbolicLinks = []; // keep a list of the symbolic link entities, if any.
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
      entity.writeContent(outputStream);
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
    final link = Link('out/${entity.fullPathName}');
    link.createSync(entity.symbolicLink!, recursive: true);
  }
}
```
#### extractFileToDisk
`extractFileToDisk` is a convenience function to extract the contents of
an archive file directory to an output directory.
The type of archive it is will be determined by the file extension.
```dart
import 'package:archive/archive_io.dart';
// ...
extractFileToDisk('test.zip', 'out');
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
extractArchiveToDisk(archive, 'out');
```

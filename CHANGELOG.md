# 4.2.0

* Optimize performance and issues with large files with XZDecoder.

# 4.1.0

* Fix: RangeError when parsing ZIP extra fields with trailing bytes.
* Optimize LZ77 decode
* Fix: issue with file_buffer preventing last value
* Fix: invalid path separator in zip content compression

# 4.0.9

* Fix extractFileToDisk file extension handling, where foo.bar.zip would fail.
* 

# 4.0.8

* Remove dependency to crypto package
* Removed Adler32 and Crc32 classes
* Fix: extractArchiveToDisk extensions should be case insensitive.
* Fix: extractFileToDisk for .tar.gz files
* Add ZipFileEncoder.addDirectorySync
* Always use posix separators for ZipFileEncoder

# 4.0.7

* Change posix dependency to 6.0.2.

# 4.0.6

* Fix zip decoding when the last file of the archive is also a zip.
* Add lastModifiedDateTime to ArchiveFile
* Fix Archive files and fileMap getting out of sync after calling removeFile

# 4.0.5

* Improve performance of OutputFileStream.
* Add ArchiveFile.noCompress, which had been removed from the 3.x to 4.x update.
* GZipDecoder should fall back to ZLib if there is no GZip header.

# 4.0.4

* Fix level argument for ZipEncoder.add method.
* Fix ArchiveFile.compression to work for controlling compression method used encoding zips.
* Add ArchiveFile.compression CompressionType.bzip2 compression mode support.
* Add ArchiveFile.compressionLevel to work for controlling compression level used for encoding zips.

# 4.0.3

* Fix potential infinite loop when parsing zip headers.
* Update conditional imports to be compatible with WASM.
* Add addFileSync to ZipFileEncoder for synchronous call to addFile.

# 4.0.2

* Reduce SDK min version to 3.0.
* Fix import error with js_interop.

# 4.0.1

* Fix error with GZip encoder for web builds.

# 4.0.0

* Major cleanup of the code, includes potential breaking changes.
  * **decodeBuffer** has been renamed to **decodeStream** in the various decoder classes.
  * **InputStream** has been renamed to **InputMemoryStream**.
  * **OutputStream** has been renamed to **OutputMemoryStream**.

# 3.6.1

* Fix ArchiveFile.rawContent returning null after decoding a zip.

# 3.6.0

* Fix zip encoding when a file was previously decoded.
* Fix decoding zips with password when using InputFileStream.
* ZipEncoder.encode autoClose now defaults to false.

# 3.5.1

* Re-add zipPath to ZipFileEncoder.

# 3.5.0

* Remove dependency to pointycastle package
* Use utf8 encoding for string data
* Fixes for encrypted zip encoding
* Async and sync versions of extractArchiveToDisk

# 3.4.10

* Fix ZipCrypto decryption

# 3.4.9

* Revert breaking change for extractArchiveToDisk becoming async;
add extractArchiveToDiskAsync for the async version.

# 3.4.8

* Improve zip decompression performance with dart:io by using native ZLib decompression when possible.

# 3.4.7

* Improve performance by not using List.setRange for copying bytes, which turns out to be very slow.

# 3.4.6

* Fix for Zip64 file size causing memory errors. 

# 3.4.5

* Rewrote InputFileStream to reduce overall memory by using a shared file cache.
* Added `DateTime lastModDateTime` getter to ArchiveFile.
* Add support for zip encryption.

# 3.4.4

* Fix for new default buffer size for InputFileStream consuming too much memory for large archives.

# 3.4.3

* Fix bug in InputFileStream that caused it to only have an 8-byte buffer, making file streaming slow.
* Increase the default buffer size for file I/O streams to 1MB.
* Update pubspec dependency versions.

# 3.4.2

* Add bzip2 decompression for zip files.

# 3.4.1

* Fix for decoding zip64 zip files that have multiple extra fields.

# 3.4.0

* Add Zip64 support to ZipEncoder to allow it to create zip files > 4GB.

# 3.3.9

* Fix for extractFileToDisk causing corrupt files by closing a file stream before it finished writing. 

# 3.3.8

* Fix for zip security issue with symlinks, https://github.com/brendan-duncan/archive/issues/265. https://osv.dev/vulnerability/GHSA-9v85-q87q-g4vg.
* Fix for zip security issue with file paths, https://github.com/brendan-duncan/archive/issues/266. https://osv.dev/vulnerability/GHSA-r285-q736-9v95.
* Add progress callback for decoding zip files.
* Don't allow tar files to include absolute paths.
* Fix error decoding AES-192.

# 3.3.7

* Add Zip AES-256 decryption
* Fix symlink encoding for tar files

# 3.3.6

* Fix errors decoding XZ files.

# 3.3.5

* Fix file content when decoding zips

# 3.3.4

* Fix analysis errors.

# 3.3.3

* Support symlinks in ZIP archives
* Fix ZIP decryption for ZipCrypto format 

# 3.3.2

* Fix for UTF-8 file name caused problem on Windows.

# 3.3.1

* Fix for Inflate crashing on some compressed files.

# 3.3.0

* IO encoders (ZipFileEncoder, TarFileEncoder), will now include directories and empty directories.
* Fix for ZipEncoder file lastModTime.
* Fix for ArchiveFile.string.
* Add PAX format to tar decoder.
* Make more file operations async. 

# 3.2.2

* Re-add List<int> content data for ArchiveFile.
* Add String and TypedData (Int32List, Float32List, etc) content data for ArchiveFile. 

# 3.2.1

* Added buffer to OutputFileStream to improve performance by reducing the number of file writes.

# 3.2.0

* For non-web applications, use native 'inflate' decompression when decompressing zip files.
* Add asyncWrite option to extractArchiveToDisk and extractFileToDisk, moving file write operations to be async.
* ArchiveFile.writeContent will release its memory after the data has been written, reducing overall memory usage.
* Add clear method to ArchiveFile, clearing any decompressed data memory it's storing.

# 3.1.11

* Fix indexing bug in Archive.addFile. 

# 3.1.10

* Fix performance regression with Archive.

# 3.1.9

* Fix FileInputStream to work with ZipDecoder.

# 3.1.8

* Catch invalid UTF8 string decoding.

# 3.1.7

* Fix for UTF8 filenames

# 3.1.6

* Fix problem with non-terminating long filenames.
* File modification dates were incorrectly stored in milliseconds instead of seconds.

# 3.1.5

* Disable XZ format CRC64 for html builds to fix errors.

# 3.1.4

* Changed LICENSE to MIT.
 
# 3.1.3

* Cleaned up LICENSE, moving other licenses to LICENSE-other.md.

# 3.1.2

* Added the ability to override the timestamp encoded in a Zip file.

# 3.1.1

* Fix zip encoder so that zip files created on Windows will open correctly on Linux.

# 3.1.0-dev

* Added `const` constructors to `ZLibDecoder`, `ZLibEncoder`, and 
  `ZLibDecoderBase`.

# 3.0.0

* Stable release supporting null safety.

# 3.0.0-nullsafety.0

* Migrate to null safety.

# 2.0.13

* Switch to dart strong mode; refactor code to resolve all dartanalyzer warnings.

# 2.0.12

* Fix dartanalyzer warnings

# 2.0.11

* Set the default permission for ArchiveFile to something more reasonable (0644 -rw-r--r--)

# 2.0.10

* Fix for decoding empty zip files.

# 2.0.9

* Add isSymbolicLink and nameOfLinkedFile to ArchiveFile.
* Fix for encoding empty files.

# 2.0.8

* Fix zip isFile

# 2.0.7

* Fix zip file attributes.

# 2.0.6

* Support GNU tar long file names
* Maintain unix file permissions in zip archives.

# 2.0.5

* Use dart:io ZLibCodec when run from dart:io.

# 2.0.4

* Fix InputStream when a Uint8ListView is used as input data.

# 2.0.3

* Use Utf8 for reading strings in archive archive files, for filenames and comments.

# 2.0.2

* Fixes for ZipFileEncoder.

# 2.0.1

* Remove the use of `part` and `part of` in the main library.
* Added ZipFileEncoder to encode files and directories using dart:io.
* Added createArchiveFromDirectory function to create an Archive object from a dart:io Directory.

# 2.0.0

* Moved version up for Dart 2 support.
* Fixed an issue with file compression flags when decoding zip archives.
* Fixed an issue with bzip2 decoding in production code.

# 1.0.33

* Support the latest version of `package:args`.

# 1.0.30

* Add archive_io sub-package for supporting file streaming rather than storing everything in memory.
  **This is a work-in-progress and under development.**

# 1.0.29

* Fix issue with POSIX tar files.
* Upgrade dependency on `archive` to `>=1.0.0 <2.0.0`

# 1.0.20

* Improve performance decompressing large files in zip archives.

# 1.0.19

* Disable CRC verification by default when decoding archives.

# 1.0.18

* Add support for encoding uncompressed files in zip archives.

# 1.0.17

* Fix a bug in InputStream.

# 1.0.16

* Add stream support to Inflate decompression.

# 1.0.15

* Improved performance when writing large blocks.

# 1.0.14

* Misc updates and fixes.

# 1.0.13

* Added BZip2 encoder.

* *BREAKING CHANGE*: `File` was renamed to `ArchiveFile`, to avoid conflicts with
  `dart:io`.

# 1.0.12

* Added BZip2 decoder.

# 1.0.11

* Changed `InputStream` to work with typed_data instead of `List<int>`, should
  reduce memory and increase performance.

# 1.0.10

* Renamed `InputBuffer` and `OutputBuffer` to `InputStream` and `OutputStream`,
  respectively.

* Added `readBits` method to `InputStream`.

# Migrating Archive 3.x to 4.x

The Archive library was originally written when the web was the primary use of Dart. File IO was less of a concern
and the design was around having everything in memory. As other uses of Dart came about, such as Flutter, a lot
of File IO operations were added to the library, but not in a very clean way.

The design goal for the 4.0 revision of the library is to ensure File IO is a primary focus, while minimizing memory
usage. Memory-only interfaces are still available for web platforms.

### InputStream and OutputStream

**InputStream** was renamed to **InputMemoryStream**.

**InputStreamBase** was was renamed to **InputStream**.

**InputFileStream** was moved to the core archive library from the archive_io library. Conditional imports are used
to ensure their use of dart:io doesn't interfere with web builds.

**OutputStream** was renamed to **OutputMemoryStream**.

**OutputStreamBase** was renamed to **OutputStream**.

**OutputFileStream** was moved to the core archive library from the archive_io library. On non-web builds, it will
throw an exception if used, as there is no file system on the web.

### File Data

#### 3.x

In 3.x, ArchiveFile had a `dynamic get content` getter, which would return the data of the file, decompressing it as
necessary.

#### 4.x

In 4.x, memory management is a priority so the design around file data has changed somewhat. The content object
of ArchiveFile was changed from __dynamic__ to a **FileContent** object, which points to the file data, either
in memory or to a position in a FileHandle.

`InputStream? ArchiveFile.getContent()` will return an InputStream object, decompressing the data in memory as
necessary.

`Uint8List? ArchiveFile.readBytes()` will do the same, but get the Uint8List of the data from the
InputStream.

`void ArchiveFile.writeContent(OutputStream output, {bool freeMemory = true})` will write the contents of the file
to an OutputStream, decompressing the data as necessary to that OutputStream without locally storing the data in
memory. If the OutputStream is a OutputFileStream, then decompression will stream directly to file output without
storing the file content in memory.

### Compression Decoders: ZLibDecoder, GZipDecoder, BZip2Decoder, XzDecoder

**decodeBytes** now return an explicit Uint8List, rather than List<int> (it was always a Uint8List).

**decodeBuffer** has been renamed to **decodeStream**. decodeStream does not return the bytes, and instead takes
an OutputStream that the data is written to. This can be an OutputMemoryStream or an OutputFileStream.

If the input of decodeStream is an InputFileStream, and the output is an OutputFileStream, decoding will be read
directly from disk, and written directly to disk, with only a file IO buffer amount of memory used.

### Compression Encoders: ZLibEncoder, GZipEncoder, BZip2Encoder, XzEncoder

**encode** method was renamed to **encodeBytes** to be consistent with decoders.

**encodeStream** was added, which take an InputStream input and an OutputStream output. This allows compression
encoders to stream data in from memory or a file, and out to memory or to a file.

### Archive Decoders: ZipDecoder, TarDecoder

**decodeBuffer** was renamed to **decodeStream*.

### Archive Encoders: ZipEncoder, TarEncoder

**encode** was renamed to **encodeBytes**.

**encodeStream** was added to write the output to an OutputStream.

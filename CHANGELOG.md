# 4.6.0

* *BREAKING CHANGE*: All decoders (`XZDecoder`, `TarDecoder`, `ZipDecoder`, `GZipDecoder`, `ZLibDecoder`,
  `BZip2Decoder` and `ZstdDecoder`) and their wrappers like `extractFileToDisk`, `extractArchiveToDisk`,
  `extractArchiveToDiskSync` now share the same contract: by default no *damaged data* errors are thrown anymore.
  If error is needed, specify `throwOnError: true` to `decodeBytes` or `decodeStream`. If checksum verification 
  is required, specify `verify: true` to `decodeBytes` or `decodeStream`: alone it reports a mismatch or damage like
  no flags do, `decodeStream` returns `false` and `decodeBytes` returns partial data, and with `throwOnError: true` as
  well a mismatch throws. All `throwOnError` are reported as `ArchiveException` and checksum exceptions with
  `ArchiveChecksumException` that extends `ArchiveException`. Read README for migration tips
  and exceptions that are still reported with original type (everything unrelated to damaged data and package code).
* *Unlike decoders mentioned above*, all new converters APIs mentioned beneath use both `verify` and
  `throwOnError` by default due to the specification of their format so that they completely coincide with dart 
  `zlib` and `gzip` transformers.
* *BREAKING CHANGE*: All decoders now properly handle `verify: true` param and do not ignore it anymore. `GZipDecoder`
  and `ZLibDecoder` that rely on dart:io implementation still may not catch the checksum issue and report an error
  with `throwOnError` for some damaged archives: a gzip whose damaged data decodes longer than its declared size
  passes as a concatenated gzip, a checksum error inside a concatenated gzip is reported as `ArchiveException`, and
  a truncated zlib stream is found only with `verify`, and thrown as `ArchiveChecksumException` with `throwOnError`
  as well. `GZipDecoderWeb` and
  `ZLibDecoderWeb` report all of these. Cut raw deflate stream (`raw: true`) is not found by any flags there,
  it has no checksum.
* *BREAKING CHANGE*: Added `writeRange` and `reserve` to `OutputStream`, and `readInto` and `viewBytes` to
  `InputStream`. All four have a default body, so a class that extends them needs no change. A class that implements
  them has to add these methods.
* Fixed `extractFileToDisk` detecting files only by extension. It now also detects them by their header bytes as all 
  platform decoders do (like MacOS, Windows, Linux). If detection by headers fails it uses old file
  extension format instead.
* Fixed `ZipDecoder` and `extractFileToDisk` throwing `Exception` for an incorrect password, or returning wrong data
  for ZipCrypto. They now throw `ArchivePasswordException` that extends `ArchiveException`. This
  exception overrules `throwOnError` and is thrown always when password does not match. AES MAC
  is checked now, a mismatch throws `ArchiveMacException` that extends `ArchiveChecksumException` regardless of flags.
* `extractArchiveToDisk` and `extractArchiveToDiskSync` throw with `ArchivePasswordException` as well for 
  bad password case.
* Added `ArchiveLimitException` that extends `ArchiveException`. It is thrown regardless of `verify` and
  `throwOnError` when decoded data is larger than `maxOutputSize`, when extracted files are larger than `maxSize`,
  when a zstd window is larger than `maxWindowSize`, when an xz block declares a dictionary larger than
  `maxDictionarySize`, when a tar long name, PAX header or sparse map is larger than `TarFile.maxMetadataSize`, and
  when a compressed zip entry decodes to more than its declared uncompressed size.
* Fixed `listTarFiles` and `extractTarFiles` silently using only the readable part of a damaged archive. They now
  throw an error for it.
* *BREAKING CHANGE*: `lastModTime` of zip entries is now in seconds since epoch, as in tar, instead of the DOS date 
  and time format. The DOS value it held before, `date << 16 | time`, is now in `ArchiveFile.lastModDosTime`.
* *BREAKING CHANGE*: `extractFileToDisk` now accepts `verify` and `throwOnError`, `extractArchiveToDisk` and 
  `extractArchiveToDiskSync` accept `throwOnError`. Without them a damaged or cut archive no longer throws: Complete 
  entries are extracted, and damaged ones leave no partial files on disk. With `throwOnError` the function throws
  an exception upon encountering the first corrupted entry, and `verify` adds checksum checks to it.
* *BREAKING CHANGE*: `CompressionType` has new values, `lzma` and `xz`, so a switch over it needs a case
  for each of them.
* Fixed `TarEncoder` writing a tar hard link read by `TarDecoder` as a symlink, which pointed to a missing file. It
  now writes it back as a hard link.
* Deprecated `AesDecrypt`, use the exported `AesCtr` instead. `AesDecrypt` is now a wrapper over `AesCtr` and gives
  the same output as before. `Sha1`, `HmacSha1`, `pbkdf2HmacSha1` and `Sha256` are exported as well.
* Fixed `ZstdDecoder` throwing `ArgumentError` for a malformed dictionary. It throws `ZstdDictionaryException`, which
  extends `ArchiveException`, since a dictionary can be damaged data as well as a wrong argument.
* Fixed `ZstdEncoder` throwing `ArgumentError` for a level above 22 or below `zstdMinLevel`. It clamps the level to
  that range, as `ZSTD_c_compressionLevel` of libzstd does. `zstdMinLevel` is -131072 instead of -7, the value of
  `ZSTD_minCLevel()`.
* Fixed `ZstdDecoder` accepting a `maxWindowSize` below 1024 bytes, the smallest zstd window. It throws
  `ArgumentError` for it.
* *BREAKING CHANGE*: `ArchiveFile.lastModDateTime` returns a local `DateTime` built from `lastModTime` in seconds
  since epoch, instead of a UTC `DateTime` built from DOS date and time fields. `ZipDecoder` takes the time from the
  UT extra field (0x5455) when the entry has one, so a zip written by `ZipEncoder` reads back the same time in every
  time zone.
* Fixed `ZipDecoder` returning the content of the first of several entries with the same name with the metadata of
  the last one. It keeps the last one, as 3.x did.
* *BREAKING CHANGE*: `extractFileToDisk` calls `callback` for a zip entry after the entry is written, as it does for
  tar. It used to call it for every zip entry while the central directory was read, before any file was written.
* Fixed `extractFileToDisk` extracting junk entries from a gzip, bzip2, xz or zstd file that does not hold a tar, also
  when its name ends with `.tar.gz` or a similar extension. It throws `ArgumentError` for such a file.
* Fixed `BZip2Decoder` returning only the first stream of concatenated bzip2 files, as `pbzip2` writes them, without
  an error. It decodes every stream in sequence, as `bzip2 -d` does.
* Fixed `ZLibDecoderWeb` appending the streams after the first of concatenated zlib streams, matching dart:io of Dart
  3.5.0, which was reverted as a bug. It decodes only the first and ignores the bytes after it, as `ZLibDecoder` on
  dart:io does since Dart 3.5.2 ([dart-lang/sdk#56481](https://github.com/dart-lang/sdk/issues/56481)).
* `extractArchiveToDisk` writes entries synchronously, as `extractArchiveToDiskSync` does, and still returns a `Future`.
* Added `allowAbsoluteSymlinks` to `extractFileToDisk`, `extractArchiveToDisk` and `extractArchiveToDiskSync`.
  Absolute symbolic links are still skipped by default.
* Extraction removes `\\?\`, `\\.\` and `\\?\UNC\` prefixes, drive letters and leading slashes from entry names, as
  bsdtar does. An entry whose name is an absolute path used to be skipped.
* Extraction skips an entry whose path runs through a symbolic link that is already in the output directory and points
  outside it, and keeps a symbolic link from the archive instead of turning it into a directory when a later entry has
  a path through it.
* `TarDecoder` with `verify` and `tarCodec.decoder` throw for a header whose size field is not a number.
* `ZipEncoder` writes the CRC and sizes in the local header of a stored entry taken from another zip, which it used to
  write with a data descriptor (#421).
* Added Dart async* `StreamTransformer`/`ByteConversionSink`/`Converter` support
  (`xzCodec`, `zstdCodec`, `bzip2Codec`, `tarCodec` and `zipCodec`) for decode and encode (decoders for
  all formats except for zip). xz, zstd and bzip2 are `Converter`s, bytes to bytes; tar and zip are
  `StreamTransformer`s: `TarDecoderTransformer`, `TarEncoderTransformer` and `ZipEncoderTransformer`.
* Added `CodecsRecognizer` with `ArchiveFormat` to recognize compressed file types with their header bytes.
* Made CRC32, SHA-256, CRC64 and Adler32 significantly faster and less RAM-consumable on all
  platforms (for `verify: true`), and SHA-1 with its HMAC and PBKDF2 and AES for AES zip.
* ZipCrypto decryption is 6.6-8.6x faster now: its keys are ints that stay exact on web instead of BigInt.
* Added `ProgressOutputStream` to monitor progress during unpack.
* Added usage examples of new apis is package readme file, shrinked amount of docs for `XZDecoder`.
* Added `XZMultithreadOptions.converter` and `ZstdMultithreadOptions.converter`, the options a
  `Converter` takes for multithreaded decoding/encoding via converter.
* Added `ultra` to `ZstdEncoderConverter` and `ZstdCodec`. Without `contentSize` levels 20-22 are reduced to 19
  unless `ultra: true` is given, as `zstd` does without `--ultra`: level 22 of unknown size takes 655 MB even for
  100 bytes of input. `ZstdEncoder` knows the input size and takes these levels without the flag.
* CRC64 for XZDecoder now works both on io and web (dart2-js) (with new `Crc64` class). Old api `isCrc64Supported`
  remained unchanged and still returns false and throws with `getCrc64` on dart2-js.
* Significantly reduced XZDecoder RAM usage for --x86, crc32, crc64, SHA-256 and default decoding with `decodeStream`.
* Reduced RAM usage used by `GZipDecoder.decodeBytes` and `ZLibDecoder.decodeBytes` on dart:io 
* Slightly reduced amount of used RAM by `ZLibDecoder`.
* Added `blockSize100k` to `BZip2Encoder.encodeBytes` and `encodeStream`
* Added `ArchiveFile.isHardLink`, set by `TarDecoder` for tar hard links. `symbolicLink` is unchanged.
* Fixed symlinks scopes for `extractFileToDisk` that could overwrite existing file on disk outside of output dir
* Fixed Unix mode reading for `ZipDecoder` for archives created on Windows.
* Fixed `ZipDecoder` reading a zip entry name that is not valid UTF-8 as Latin-1. It reads it as CP437, the encoding
  zip tools use when the UTF-8 flag is not set, so such names list differently than in 4.5.1. Pass
  `ZipDecoder(filenameEncoding:)` to read them in another encoding.
* Fixed `ZipDecoder` ignoring the Info-ZIP Unicode Path extra field (0x7075). An entry that has one lists under the
  UTF-8 name from that field, so names differ from 4.5.1. The field is used only when its CRC matches the stored name.
* Fixed CRC64 `XZEncoder` files created on dart-js failed to decode on native platforms.
* Fixed `ZLibDecoder` on web.
* `TarEncoder` now writes `"ustar\0"` magic in header for easier recognition.
* `TarEncoder` now writes non-ASCII names and symlink targets as PAX path/linkpath records, so readers that take
  header bytes in a local code page, such as Windows tar.exe, get the right names.
* Zip passwords are now encoded as UTF-8 to properly handle non-ASCII passwords. `ZipDecoder` tries UTF-8 first 
  and then bytes that older versions of the package wrote.
* Fixed `ZipDecoder` decrypting AES and ZipCrypto entries inside the buffer, what corrupted it.
* Fixed(added) LZMA decoding for `ZipDecoder` and encoding for `ZipEncoder` with `CompressionType.lzma`. Encoder
  still falls back to DEFLATE, but decoder properly reads lzma data.
* `ZipDecoder` now reads zstd (method 93) and xz (method 95) zip entries as `CompressionType.zstd` and
  `CompressionType.xz`, and `ZipEncoder` writes them with `ZstdEncoder` and `XZEncoder`. `XZEncoder` stores data
  uncompressed, so an xz entry is not smaller than its data.
* `TarDecoder` and `tarCodec.decoder` now read sparse files the way libarchive does: old GNU sparse headers with
  extension blocks and PAX sparse formats 0.0, 0.1 and 1.0. Holes are expanded when the content is read.
* Fixed `mode` 0 file rights for `ArchiveFile` from `ZipDecoder` created on Windows.
* Fixed SHA-256 checks for XZDecoder with `verify: true`.
* Fixed symlinks encoding in `ZipEncoder` and decoding non-ASCII names with macos unzip from archives of this package.
* Fixed latin1 encoding for `TarEncoder` with non-ASCII file names.
* Fixed `ArchiveFile.directory` mode (0755 instead of 0644) so that it can be opened after unpacking.
* Fixed a few cases with accepting corrupted file in `XZDecoder`.
* Fixed some 7z files failed to decode with `XZDecoder`.
* Fixed invalid bzip2 archive returned true from `decodeStream`.
* Fixed `BZip2Decoder` throwing `RangeError` on an archive cut inside a block when it read from an
  `InputMemoryStream`. Both memory and file streams return false now, without inconsistency.
* Fixed a zip entry compressed with bzip2 handing back short data with no error when the entry is
  damaged. It throws `ArchiveException` now, the way a damaged deflate entry already did.
* Fixed file names trimming in TAR.
* `ZipEncoder` now applies CompressionType.none to entries with no content.
* Replaced `ChunkedConversionSink` with `ZLibOutputSink` for gzip and zlib to forward every piece the codec produces 
  instead of holding it to the end.
* Fixed tar stream decoder allocating whatever a GNU long name or PAX header declared, before any of
  those bytes arrived. A 512 byte header claiming 2^40 was an out of memory kill; the buffer now
  grows with what actually arrives.
* Fixed `ZipEncoder` with a password writing a stale MAC into entries that have no content, such as
  every directory. The local header declared 12 bytes it never wrote, which left every local header
  after it off by 2 and unreachable to a forward-only reader.
* Added `ZipEncoder(streamed: true)` that writes entries as they are read, with low RAM usage on big files
  (4GB+, uses zip64 format from zip APPNOTE).
* Fixed decoding zip64 with `ZipDecoder`.
* Multithreaded `XZDecoder.decodeStream` now stops at the first broken block, like the single threaded one.
* Fixed `ZipDecoder` returning an empty archive for a zip with extra bytes in front of it (self extracting zips).
* Fixed `ZipDecoder` throwing `RangeError` instead of `ArchiveException` for some damaged zips.
* Fixed `LzmaDecoder` throwing `RangeError` for truncated or damaged LZMA data, and `XZDecoder` reading more bytes
  than the input has for a stream cut inside a stream header, block header, LZMA2 chunk header, index or footer. They
  throw `ArchiveException` and report a truncated stream.
* Fixed `TarDecoder` adding garbage folders to names in archives made by GNU tar `--incremental`.
* Fixed `TarDecoder` treating some folder entries (GNU and very old tar formats) as files.
* Fixed `TarDecoder` long names in archives made by older versions of this package.
* Fixed `BZip2Decoder` rejecting some valid archives and data after the end of an archive, same as bzip2 1.0.8.
* Fixed `XZDecoder` failing on archives larger than 4 GB on the web.
* Fixed `InputFileStream.toUint8List` and `readBytes` returning wrong bytes when a file is read in parts.
* `GZipDecoderWeb` and `ZLibDecoderWeb` are ~60x faster when writing to a file now.
* Fixed `ZipEncoder` emptying `ArchiveFile.stream` entries, so they could not be read after encoding.
* Fixed `ZipEncoder` with a password changing the original data of entries in memory.
* Fixed `extractFileToDisk` never returning when the output drive does not exist.
* Fixed multithreaded `XZDecoder` hanging on a truncated file and accepting some damaged archives that single
  threaded decoding refused.
* Fixed `BZip2Decoder` crashing on an archive that declares block size 0.
* Fixed `ZipDecoder` with `verify: true` rejecting AES zips that store no CRC.
* Fixed `ZipEncoder` writing a wrong CRC when encoding again an archive decoded from an AES zip
* Fixed a stored zip entry reading back empty after it was written to a file.
* `ArchiveFile.stream` now takes the stream from its current position instead of from the start.
* Fixed `ZipEncoder` failing to create on the web.
* `TarDecoder` with `verify: true` now reports a file that is cut short, like other tar tools do.
* Fixed `ZipEncoder` zip64 for small files that follow large ones and for entries over 4 GB.
* Fixed `InputFileStream` ignoring its `byteOrder` for `readUint16`, `readUint24`, `readUint32` and `readUint64`.
* Fixed `ZLibDecoderWeb` and `GZipDecoderWeb` depending on the byte order of the input stream: `decodeStream`
  failed `verify` on a whole zlib stream from a little-endian stream, and gzip failed on a big-endian one.
* Fixed not-restoring original InputStream endian for some decoders and encoders and decoding/encoding BigEndian files.
* Fixed `ZLibDecoderWeb` dropping the decoded data when bytes follow the stream, and accepting an empty input.
* Fixed `ZipDecoder` returning the raw compressed bytes as the content of an entry with an unsupported compression
  method. With `throwOnError` or `verify` reading that entry throws `ArchiveException`, without them it is empty,
  and `extractFileToDisk` skips it and extracts the rest.
* Fixed an empty zip password encrypting and decrypting entries with an empty key.
* Fixed ZipDecoder allocating size of a deflate entry over 500 MB, which threw `OutOfMemoryError` for a zip64 entry
  that claims terabytes.
* Fixed `listTarFiles` listing a plain .tar as empty, and `listTarFiles` and `extractTarFiles` leaving open files 
  and temporary folders uncleaned.
* Fixed `ZLibDecoderWeb` and `GZipDecoderWeb` accepting malformed deflate: a zlib header with a method other than
  deflate or a window over 32 KB, a stream without its final block, and an oversubscribed Huffman table, which
  decoded to garbage before, are now reported with `throwOnError` and `verify`.
* Fixed `ZipFileEncoder.store` writing entries as deflate level 0 and holding each whole entry in memory: a 1 GB
  file needed 2 GB of RAM. The `store` level of `create`, `zipDirectory`, `addFile`, `addFileSync` and
  `addDirectory` now writes uncompressed entries (method 0) streamed from the file. An `ArchiveFile` given to
  `addArchiveFile` is stored too, unless its `compression` is set.
* Fixed `ZipFileEncoder` holding each whole deflated entry in memory: a 920 MB file needed 1042 MB of RAM at level 1
  and 667 MB at level 6, now 19 MB at every level. `ZipFileEncoder` now uses `ZipEncoder(streamed: true)`, so a
  deflated entry without a password has bit 3 set, zero CRC and sizes in its local header, and a data descriptor
  after its data. The archives decode the same, but their bytes differ from earlier versions.
* Fixed `OutputFileStream.writeStream` moving the read position of its source to the end, unlike the other
  `OutputStream` types. The source position is now left unchanged.

# 4.5.2

* Fixed `ZipDecoder.decodeStream` returning an empty archive when the
  input was not at position 0, such as after reading a magic number or
  decoding the same stream a second time (#405). `decodeStream` also
  leaves the input's read position where it was.
* Added `InputStream.totalLength`, the size of the whole stream whatever
  the read position, where `length` is only the bytes after it.

# 4.5.1

* Fixed zips written on the web, which decoded to nothing: the zlib encoder
  left the zip encoder's output big-endian, so every header after the first
  entry's data was written in the wrong byte order (#419).
* `ZipEncoder` can be used under dart2js on Node, where creating its secure
  random source threw; it is now only created for a password.
* Fixed zips written by `ZipEncoder` since 4.4.0, which 7-Zip reported
  as having header errors: the data descriptor flag was set in each
  entry's local header but not its central directory header. The UTF-8
  flag also went into the central directory even for names that were not
  UTF-8.
* Directory entries are stored rather than written as an empty deflate
  stream, which `unzip` rejected, and carry the MS-DOS directory
  attribute. In a zip with a password they are no longer marked
  encrypted.
* Entries whose content is in memory, and stored entries that can be read
  twice, have their CRC and sizes in the local header again rather than in
  a data descriptor after the data. Java's `ZipInputStream` refuses a
  stored entry with a descriptor, and OpenDocument and EPUB files need
  their stored `mimetype` entry without one (#421).

# 4.5.0

* Security: `XZDecoder` hung forever on a truncated `.xz` read from a
  file or a decode stream, including `.tar.xz` in `extractFileToDisk`.
* Security: tar long name and pax header entries are limited to
  `TarFile.maxMetadataSize` (1 MB). A small `.tar.gz` could declare one
  large enough to take gigabytes of memory to read.
* Security: decoding had no output limit, so a small archive could expand
  to fill memory or disk. Added `maxOutputSize` to `decodeBytes` and
  `decodeStream` on `GZipDecoder`, `ZLibDecoder`, `BZip2Decoder` and
  `ZstdDecoder`, and `maxSize` to `extractFileToDisk`,
  `extractArchiveToDisk` and `extractArchiveToDiskSync`.
* A zip entry is no longer decoded past the uncompressed size the archive
  gives for it, so `ArchiveFile.size` can be checked before reading.
* Security: `ZstdDecoder` sized its window and output from the frame header,
  so a 10 byte input committed hundreds of MB, even past `maxWindowSize`.
  The content size is now checked as each block decodes, and one that
  overflows is refused.
* Security: `XZDecoder` limits the LZMA2 dictionary an archive may declare
  to `maxDictionarySize` (256 MB by default), which bounds the memory a
  streaming decode takes. It also takes `maxOutputSize`, and no longer
  preallocates gigabytes because a tiny archive's index claims them.
* Multithreaded xz decoding checks each block against the size the index
  gives it. An index that misstated one used to make the ordered output
  hold everything after it in memory and report success with the output
  cut short. Blocks are no longer let run far ahead of the output.
* Security: extraction creates symbolic links after every other entry and
  refuses one whose path runs through another link. A chain of links that
  each looked safe on its own could place a file outside the output
  directory.
* Security: `extractTarFiles` did not keep entries inside the output
  directory. It now extracts as `extractFileToDisk` does, decoding as it
  reads rather than through a temp file it left behind.
* Extraction reports an entry that fails to decode instead of leaving a
  partial file without a word, and an empty file no longer takes a 1 MB
  write buffer.
* A tar hard link, which is extracted as a symbolic link, now points at its
  target from the link's own directory.
* `TarDecoder.decodeStream` and `decodeBytes` take `keepEntries`. False
  passes entries only to the callback, so memory no longer grows with the
  entry count; `extractFileToDisk` uses it. A `.tar.gz` of a million empty
  entries now decodes in 39 MB rather than 326 MB.
* Malformed zip headers, such as an odd length extra field on an encrypted
  entry or a zip64 locator pointing past the file, threw `RangeError`
  instead of `ArchiveException`. The AES extra field is also found when
  other extra fields come before it.
* `BZip2Decoder` accepts a block declaring more than 18002 selectors and
  ignores the extra ones, as libbzip2 does, instead of reporting a
  truncated stream.
* Reading a zip entry no longer preallocates its declared size when the
  compressed data could not expand that far.

# 4.4.0

* Security: a crafted zip64 compressed size overflowed the stream bounds
  checks and could crash the decoder while reading an untrusted archive.
  Sizes are now clamped to the bytes actually present.
* Added `InputDecodeStream` and `decodeLazy` on `GZipDecoder`, `ZLibDecoder`,
  `BZip2Decoder`, `ZstdDecoder` and `XZDecoder`, which decode a stream as it
  is read so a large archive can be piped into another decoder without a temp
  file.
* `extractFileToDisk` extracts `.tar.gz`, `.tar.bz2`, `.tar.xz` and
  `.tar.zst` in a single pass, writing each entry as it is reached, with no
  temp file.
* Decoding and encoding no longer buffer the whole file: gzip and zlib
  streaming, `ZipEncoder`, and encrypted zip entries (ZipCrypto and AES) now
  work in a bounded amount of memory whatever the file size.
* Encrypted zip entries are decrypted as they are read; a wrong password now
  surfaces when the content is read.
* Faster decoding: `getCrc32` is about three times quicker on typed data, and
  `InputFileStream` reads in larger blocks.
* Fixed `XZEncoder`, which produced archives other tools rejected for inputs
  of 128 bytes or more.

# 4.3.0

* Added `ZstdDecoder`, a pure Dart decoder for the zstd (Zstandard) format. 
* Added `ZstdEncoder`, a pure Dart zstd encoder for the VM, JavaScript and
  wasm, at levels -7 to 22.
* Zip entries compressed with zstd.
* `extractFileToDisk` and the tar command accept `.tar.zst` and `.tzst`, and
  `TarFileEncoder.tarDirectory` can write `.tar.zst` with
  `compression: TarFileEncoder.zstd`.
* Added multithreaded decoding to XZDecoder. Passing an `XZMultithreadOptions`
  to `decodeBytes` or `decodeStream` spreads the work over isolates, one xz
  block per job, and reports the result through its `onDone` callback. Both
  methods behave exactly as before when it is omitted. On a 1.1 GB archive of
  six blocks: 16.1 s single threaded, 8.0 s on the default three workers,
  5.0 s on six.
* `decodeStream` reading from an `InputFileStream` now lets each worker read
  its own block straight from disk, so the compressed archive never passes
  through the calling isolate. Decoding a 1.1 GB archive to an
  `OutputFileStream` peaks at 1.8 GB, below the 3.0 GB the single threaded
  path uses, while being twice as fast.
* Multithreaded decoding falls back to the single threaded path on the web,
  where there are no isolates, and the isolate machinery is tree-shaken out of
  web builds entirely.
* Added `InputFileStream.fileBuffer`, `fileOffset` and `fileLength`.
* Added `--x86` flag support to XZDecoder
* Improved verify: true speed for XZDecoder
* Improved overall decode speed for XZDecoder
* Decreased RAM usage for XZDecoder
* Added concatenated streams support for XZDecoder
* Added crc64 wasm support (`verify: true`)
* Added `uncompressedSize` getter for XZDecoder, returning the original file
  size before compression.
* Fix: pb=4 flag range error in XZDecoder
* Fix: padding for _streamStart in XZDecoder
* Added `throwOnError` to `XZDecoder.decodeBytes` and `decodeStream`. Without
  it a malformed or
  truncated archive still returns the partial output with nothing to say it is
  not the whole file, which was the only decode with no way at all to report a
  failure. In multithreaded mode the exception is delivered to
  `XZMultithreadOptions.onError`, and setting `throwOnError` without an
  `onError` is now refused rather than losing the failure.
* Fix: a corrupt xz block lost the part of itself that had already decoded when
  `verify: true` was used with an output that cannot be read back, such as an
  `OutputFileStream` or any multithreaded decode. The output now stops in the
  same place whichever way the decode was asked for.
* Added `XZDecoder.maxPreallocateSize`, capping how large an output buffer is
  allocated from a size the archive itself declares. Defaults to
  `xzDefaultMaxPreallocateSize`, 2 GB natively and 256 MB on the web.
* Added `XZMultithreadOptions.fileReadBufferSize`.
* Fix: an `xz --check=none` archive with corrupt blocks passed `verify: true`.
* Fix: the xz block header reader trusted its own fields, accepting an
  unterminated multibyte integer, a filter properties length past the end of
  the header, empty delta or LZMA2 properties, and a bad stream header or
  footer CRC.
* Fix: the zip End of Central Directory record was missed when its signature
  straddled a chunk of the backwards search, or sat within the last 21 bytes of
  the file, so a valid archive could decode as empty.
* `TarDecoder` with `verify: true` now checks each header's own checksum and
  throws `ArchiveException` on a mismatch.
* Fix: GNU base-256 numeric tar header fields were read as octal, so sizes of
  8 GB or more and large uid, gid and mtime values decoded as garbage.
* Fix: tar PAX extended headers are walked by each record's declared length
  instead of split on newlines, so a record holding binary no longer corrupts
  the rest of the header.
* Fix: a PAX `size` record was applied to the metadata headers following it
  rather than to the entry it describes.
* Fix: a GNU `././@LongLink` header of type `K` set the next entry's name
  instead of its symlink target.
* Fix: `storeData: false` skipped the tar long name and PAX headers along with
  the file data, losing the names they carry.
* Fix: a negative size in a tar header is refused instead of read as an entry.
* Fix: with `verify: true` the end of a tar is a full 512 byte zero block, which
  two zero bytes could not be told apart from a damaged header. A tail shorter
  than a header block now ends the archive instead of decoding as junk.
* Fix: tar base-256 fields wider than `TarFile.maxNumericField` are refused on
  read and write instead of overflowing silently.
* Fix: decoded regular tar files were given an empty link name and re-encoded
  as symlinks.
* Fix: long tar names and symlink targets were written without the `L` and `K`
  type flags, so other tar implementations truncated them to 100 bytes, and
  long symlink targets were not written at all.
* Fix: the GNU long name record was sized in characters rather than encoded
  bytes and ignored `filenameEncoding`.
* Fix: encoding a tar entry consumed the stream it was given, so a second
  encode of the same archive wrote empty entries.
* Fix: tar values too wide for the octal header field are written in GNU
  base-256 form instead of producing a corrupt header.
* `TarEncoder` copies a stored stream through in chunks rather than reading the
  whole entry into memory.
* `TarFile.content` is now settable and reads back what was set.
* Fix: `GZipDecoder.decodeStream` returned true for a truncated or corrupt
  archive, silently losing files.
* Fix: the web gzip decoder never checked the member CRC32 despite
  `verify: true`.
* Fix: the web gzip header reader trusted its own length fields, reading past
  the end on a damaged extra field, an unterminated name or comment, or a
  header under ten bytes.
* Fix: a gzip input under 20 bytes had header bytes read as a trailer.
* The native gzip decoder now reads in 8 KB chunks instead of 1 KB.
* Fix: an incomplete Huffman code table entry consumed no bits and looped
  forever, and a code length repeat past the end of the table indexed out of
  range.
* Fix: an Inflate back-reference distance reaching past everything written
  indexed behind the output buffer.
* Fix: the web zlib decoder read its two byte header without checking two bytes
  were there.
* Fix: a short read near the end of a file overwrote the buffer's size with the
  bytes read, so every later read missed the cache and went back to disk.
* Fix: multi-byte `FileBuffer` reads refilled the cache one byte early, costing
  a re-read on every buffer-aligned access.
* Fix: `InputFileStream.subset` did not clamp its length to what remains of the
  source, so peeking past the end returned stale bytes.
* Deprecated the `fileSize` parameter of the `FileBuffer` read methods, which
  is ignored.


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

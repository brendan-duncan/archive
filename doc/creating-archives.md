# Creating archives

Build an `Archive` of `ArchiveFile` entries, then encode it with
`ZipEncoder` or `TarEncoder`. On native platforms, `ZipFileEncoder` and
`TarFileEncoder` write directories and files straight to disk.

## Entries

| Constructor | Content |
|---|---|
| `ArchiveFile.bytes(name, bytes)` | A `List<int>` in memory. |
| `ArchiveFile.typedData(name, typedData)` | Any `TypedData`, viewed as bytes. |
| `ArchiveFile.string(name, text)` | Text, encoded as UTF-8. |
| `ArchiveFile.stream(name, inputStream)` | Read from an `InputStream` when encoding, e.g. an `InputFileStream`. |
| `ArchiveFile.directory(name)` | A directory entry. |
| `ArchiveFile.symlink(name, target)` | A symbolic link (tar only; see below). |
| `ArchiveFile.noCompress(name, size, bytes)` | Bytes stored without compression in a zip. |
| `ArchiveFile(name, size, bytes)` | Older form of `.bytes`. |

Set `mode` (Unix permissions, default `0644`), `lastModTime` (seconds since
the epoch, default now), `ownerId`/`groupId` and `comment` as needed.
Adding an entry whose name is already in the archive replaces it.

```dart
final archive = Archive();
archive.add(ArchiveFile.string('notes.txt', 'Some text'));
archive.add(ArchiveFile.bytes('image.png', pngBytes));
archive.add(ArchiveFile.directory('empty/'));
archive.add(ArchiveFile.stream('big.log', InputFileStream('big.log')));
```

Use `/` in entry names. `ZipEncoder` converts `\` to `/`; `TarEncoder` does
not.

## Zip

```dart
final zipBytes = ZipEncoder().encodeBytes(archive);
```

The compression level applies to deflate (0 to 9) and zstd (see
[compression](compression.md#zstd)). The default is
`DeflateLevel.bestSpeed` (1).

```dart
final zip = ZipEncoder()
    .encodeBytes(archive, level: DeflateLevel.bestCompression);
```

Each entry can choose its own method and level, which take precedence over
the encoder's level:

```dart
archive.add(ArchiveFile.bytes('photo.jpg', jpgBytes)
  ..compression = CompressionType.none); // already compressed, store it
archive.add(ArchiveFile.string('data.json', jsonText)
  ..compression = CompressionType.zstd
  ..compressionLevel = 19);
```

`CompressionType` is `deflate` (the default), `bzip2`, `zstd` or `none`.
Not every zip reader supports bzip2 or zstd entries; deflate is the safe
choice when you don't control the reader.

Other options:

- `ZipEncoder(password: '...')` encrypts every entry with AES-256 (WinZip
  AE-1). ZipCrypto is not available for writing.
- `ZipEncoder(filenameEncoding: ...)` for names in an encoding other than
  UTF-8.
- `modified:` on `encodeBytes`/`encodeStream` sets one timestamp for every
  entry.
- `archive.comment` is written as the zip comment.
- Zip64 headers are added automatically for entries or archives over 4 GB.

Entries that came from a decoded zip are copied without being decompressed
and recompressed.

### Writing a zip to a file

`encodeBytes` builds the whole zip in memory. To write to a file, or to add
entries one at a time, use the incremental API with an `OutputFileStream`:

```dart
final output = OutputFileStream('out.zip');
final encoder = ZipEncoder();
encoder.startEncode(output);
encoder.add(ArchiveFile.stream('big.log', InputFileStream('big.log')));
encoder.add(ArchiveFile.string('readme.txt', 'hello'));
encoder.endEncode();
await output.close();
```

`add` closes each entry's input once it is written (`autoClose`, default
true). `ZipEncoder().encodeStream(archive, output)` encodes a whole
`Archive` the same way, but leaves inputs open unless you pass
`autoClose: true`.

### Zipping files and directories (native)

```dart
// Zip a whole directory to assets.zip, next to it.
await ZipFileEncoder().zipDirectory(Directory('assets'));

// Or choose what goes in.
final encoder = ZipFileEncoder();
encoder.create('bundle.zip', level: DeflateLevel.defaultCompression);
await encoder.addDirectory(Directory('assets'), filter: (entity, progress) {
  return entity.path.endsWith('.bin')
      ? ZipFileOperation.skip
      : ZipFileOperation.include;
});
await encoder.addFile(File('big.log'), 'logs/big.log');
encoder.addArchiveFile(ArchiveFile.string('VERSION', '1.0.0'));
await encoder.close();
```

- `zipDirectory(dir, filename: ...)` writes `<dir>.zip` unless `filename`
  is given (which must not be inside `dir`). Entry names are relative to
  `dir`. It also takes `level`, `followLinks`, `modified`, `onProgress` and
  `filter`.
- `addDirectory(dir)` includes the directory's own name in entry paths
  unless `includeDirName: false`.
- `filter` returns `ZipFileOperation.include`, `skip` or `cancel` for each
  file system entity.
- `ZipFileEncoder(password: ...)` encrypts with AES-256.
- Files are read from disk as they are compressed; nothing is held whole in
  memory.
- `addDirectorySync`, `addFileSync` and `closeSync` are synchronous
  versions.

## Tar

```dart
final archive = Archive()
  ..add(ArchiveFile.string('bin/run.sh', '#!/bin/sh\necho hi\n')
    ..mode = 0x1ed) // 0755
  ..add(ArchiveFile.symlink('run', 'bin/run.sh'));
final tar = TarEncoder().encodeBytes(archive);
```

`TarEncoder` writes ustar headers, with GNU long name and long link entries
for paths over 100 bytes. It stores mode, owner and group IDs, modification
time and symbolic links. Use `encodeStream(archive, outputStream)` to write
to a file, or `start(output)`, `add(entry)` and `finish()` to add entries one
at a time.

### Compressed tar

Pass the tar through a codec:

```dart
final tgz = GZipEncoder().encodeBytes(tar);
final tzst = ZstdEncoder().encodeBytes(tar, level: 19);
final tbz = BZip2Encoder().encodeBytes(tar);
```

`XZEncoder` stores data without compressing it, so it is not useful for
`.tar.xz`.

There is no encoder that writes into another encoder as it goes. For large
files, write the tar to a file first, then compress that file:

```dart
final tarOut = OutputFileStream('logs.tar');
final archive = createArchiveFromDirectory(Directory('assets'));
TarEncoder().encodeStream(archive, tarOut);
await tarOut.close();
await archive.clear();

final input = InputFileStream('logs.tar');
final output = OutputFileStream('logs.tar.bz2');
BZip2Encoder().encodeStream(input, output);
await input.close();
await output.close();
```

### Tarring directories (native)

```dart
// Writes assets.tar.gz next to the directory.
await TarFileEncoder().tarDirectory(Directory('assets'),
    compression: TarFileEncoder.gzip);

// Or build one up.
final encoder = TarFileEncoder();
encoder.create('logs.tar');
await encoder.addFile(File('big.log'));
await encoder.addDirectory(Directory('assets'));
await encoder.close();
```

`tarDirectory` takes `compression: TarFileEncoder.store` (the default,
`.tar`), `TarFileEncoder.gzip` (`.tar.gz`) or `TarFileEncoder.zstd`
(`.tar.zst`), plus `filename`, `level`, `followLinks` and `filter`. When
compressing it writes a temporary tar first.

`createArchiveFromDirectory(dir)` returns an `Archive` of a directory's
files for use with either encoder. Contents are read when encoded, but every
file is opened up front, so for very large directories prefer
`ZipFileEncoder` or `TarFileEncoder`, which open one file at a time.

`TarFileEncoder` and `createArchiveFromDirectory` take entry names from
the file system as-is, so on Windows they contain `\`. Prefer `ZipEncoder`
there, or build the `Archive` yourself with `/` separators.

## Symbolic links

Only `TarEncoder` writes symbolic links. `ZipEncoder` cannot encode an
`ArchiveFile.symlink` entry; leave links out of archives you encode as zip.

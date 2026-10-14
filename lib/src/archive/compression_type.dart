/// The format of the compression an [ArchiveFile] is stored with.
///
/// [lzma] is only decoded. `ZipEncoder` writes a new [lzma] entry with
/// deflate, and an entry copied from a zip keeps its LZMA data.
enum CompressionType { none, deflate, bzip2, zstd, lzma, xz }

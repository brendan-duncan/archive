/// The format of the compression an [ArchiveFile] is stored with.
///
/// Decoding a zip file sets each entry's compression to the method it was
/// stored with.
enum CompressionType { none, deflate, bzip2, zstd }

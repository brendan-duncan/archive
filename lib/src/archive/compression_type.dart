/// The format of the compression an [ArchiveFile] is stored with.
///
/// Decoding a zip file sets each entry's compression to the method it was
/// stored with. [zstd] can be decoded but not yet encoded, so a file that has
/// to be compressed anew with it is compressed with [deflate] instead.
enum CompressionType { none, deflate, bzip2, zstd }

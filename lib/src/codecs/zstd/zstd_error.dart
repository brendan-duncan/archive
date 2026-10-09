/// Thrown inside the zstd decoder when the data is malformed. The public
/// decoder turns it into a false return or an ArchiveException.
class ZstdFormatError implements Exception {
  final String message;

  ZstdFormatError(this.message);

  @override
  String toString() => message;
}

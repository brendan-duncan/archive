/// An exception thrown when there was a problem in the archive library.
class ArchiveException extends FormatException {
  ArchiveException(super.message, [super.source, super.offset]);
}

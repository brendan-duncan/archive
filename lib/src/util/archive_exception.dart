
/// An exception thrown when there was a problem in the archive library.
class ArchiveException extends FormatException {
  ArchiveException(String message, [var source, var offset])
    : super(message, source, offset);
}

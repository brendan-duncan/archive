part of archive;

class ArchiveException {
  String reason;

  ArchiveException(this.reason);

  String toString() => reason;
}

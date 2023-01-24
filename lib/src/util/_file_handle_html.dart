import 'archive_exception.dart';

class FileHandle {
  FileHandle() {
    throw ArchiveException('FileHandle is not supported on this platform.');
  }
}

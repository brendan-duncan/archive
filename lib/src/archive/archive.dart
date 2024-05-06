import 'archive_directory.dart';
import 'archive_file.dart';

/// An [Archive] represents a file system, as a collection of [ArchiveEntity]
/// objects, which are either an [ArchiveFile] or an [ArchiveDirectory].
/// Zip and Tar codecs work with Archives, where decoders will convert a zip or
/// tar file into an [Archive] and encoders will convert an [Archive] into a zip
/// or tar file. An [ArchiveDirectory] can contain other [ArchiveDirectory] or
/// [ArchiveFile] objects, making a hierarchy filesystem.
class Archive extends ArchiveDirectory {
  List<ArchiveFile>? _files;

  Archive([super.name = '']) : super();

  /// Shortcut for [getAllFiles]. The file list is cached, so getting
  /// files multiple times will not result in multiple calls to [getAllFiles].
  List<ArchiveFile> get files {
    if (_files == null) {
      _files = getAllFiles();
    }
    return _files!;
  }
}

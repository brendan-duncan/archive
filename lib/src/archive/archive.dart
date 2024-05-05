import 'archive_directory.dart';

/// An [Archive] represents a file system, as a collection of [ArchiveEntity]
/// objects, which are either an [ArchiveFile] or an [ArchiveDirectory].
/// Zip and Tar codecs work with Archives, where decoders will convert a zip or
/// tar file into an [Archive] and encoders will convert an [Archive] into a zip
/// or tar file. An [ArchiveDirectory] can contain other [ArchiveDirectory] or
/// [ArchiveFile] objects, making a hierarchy filesystem.
class Archive extends ArchiveDirectory {
  Archive([super.name = '']) : super();
}

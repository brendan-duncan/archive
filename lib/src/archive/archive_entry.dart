import 'dart:typed_data';

import '../util/input_stream.dart';

/// A callback function called when archive entries are read from or written
/// to archive files like zip or tar.
typedef ArchiveCallback = void Function(ArchiveEntry entry);

/// Base class for either an [ArchiveFile] or an [ArchiveDirectory].
abstract class ArchiveEntry extends Iterable<ArchiveEntry> {
  /// The name of the file or directory.
  String name;
  /// The access mode of the file or directory.
  int mode;
  /// The owner id of the file or directory.
  int ownerId = 0;
  /// The group id of the file or directory.
  int groupId = 0;
  /// The creation timestamp of the file or directory, in seconds from
  /// epoch.
  int creationTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  /// The timestamp the file or directory was last modified, in seconds since
  /// epoch.
  late int lastModTime;
  /// If symbolicLink is not null, the entry is a symbolic link and this is
  /// the path to what it's linking to. This should be an archive relative path.
  /// Symlinks pointing outside of the archive will be invalid when extracting
  /// archives to disk.
  String? symbolicLink;
  /// True if the entry is a symbolic link, otherwise false.
  bool get isSymbolicLink => symbolicLink?.isNotEmpty ?? false;
  /// The crc32 checksum of the uncompressed content.
  int? crc32;
  /// An optional comment for the archive entry.
  String? comment;
  /// The parent [ArchiveDirectory] of the entry.
  ArchiveEntry? parent;

  ArchiveEntry({required String name, required this.mode})
      : name = name.replaceAll('\\', '/') {
    lastModTime = creationTime;
  }

  /// True if the entry is an [ArchiveFile], otherwise false.
  bool get isFile;
  /// True if the entry is an [ArchiveDirectory], otherwise false.
  bool get isDirectory => !isFile;

  /// The full archive-relative path of the entry, including parent directories.
  String get fullPathName => parent != null && parent!.fullPathName.isNotEmpty
      ? '${parent!.fullPathName}/$name'
      : name;

  /// Asynchronously close the file.
  Future<void> close();

  /// Synchronously close the file.
  void closeSync();

  /// Asynchronously clear any cached data associated with the file.
  Future<void> clear() async {}

  /// Synchronously clear any cached data associated with the file.
  void clearSync() async {}

  /// If this is a [ArchiveDirectory], returns the first child entry,
  /// otherwise this is returned.
  @override
  ArchiveEntry get first => this;

  /// If this is a [ArchiveDirectory], returns the last child entry,
  /// otherwise this is returned.
  @override
  ArchiveEntry get last => this;

  /// If this is an [ArchiveDirectory], returns whether the directory is
  /// empty, otherwise true is returned for files.
  @override
  bool get isEmpty => true;

  /// Returns true if there is at least one element in this collection.
  @override
  bool get isNotEmpty => false;

  /// If this is an [ArchiveDirectory], returns the number of children of
  /// the directory, otherwise returns 1 for files.
  @override
  int get length => 1;

  /// The uncompressed size, if it's a file, otherwise 0 for directories.
  int get size => 0;

  /// Get an child entry if this is a diretory, otherwise this is returned.
  ArchiveEntry operator [](int index) => this;

  /// Get the children iterator.
  @override
  Iterator<ArchiveEntry> get iterator => [this].iterator;

  /// Returns the full path of the entry.
  @override
  String toString() => fullPathName;

  /// If this is an [ArchiveFile] returns the content stream of the file
  /// contents, otherwise null is returned for directories.
  /// The content stream will either be a [InputMemoryStream], if the archive
  /// was opened with an [InputMemoryStream], or a [InputFileStream] if the
  /// archive was opened with an [InputFileStream].
  InputStream? getContent() => null;

  /// Return the decompressed bytes of the file if this is an [ArchiveFile],
  /// otherwise null is returned for directories.
  Uint8List? readBytes() => null;
}

import 'dart:typed_data';

import '../util/input_stream.dart';

typedef ArchiveCallback = void Function(ArchiveEntry entry);

/// Either an ArchiveFile or an ArchiveDirectory
abstract class ArchiveEntry extends Iterable<ArchiveEntry> {
  String name;
  int mode;
  int ownerId = 0;
  int groupId = 0;
  int creationTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Seconds since epoch
  late int lastModTime;

  /// If symbolicLink is not null, the entry is a symbolic link and this is
  /// the path to what it's linking to. This should be an archive relative path.
  String? symbolicLink;

  bool get isSymbolicLink => symbolicLink?.isNotEmpty ?? false;

  /// The crc32 checksum of the uncompressed content.
  int? crc32;
  String? comment;
  ArchiveEntry? parent;

  ArchiveEntry({required String name, required this.mode})
      : name = name.replaceAll('\\', '/') {
    lastModTime = creationTime;
  }

  bool get isFile;
  bool get isDirectory => !isFile;

  String get fullPathName => parent != null && parent!.fullPathName.isNotEmpty
      ? '${parent!.fullPathName}/$name'
      : name;

  Future<void> close();

  void closeSync();

  Future<void> clear() async {}

  void clearSync() async {}

  @override
  ArchiveEntry get first => this;

  @override
  ArchiveEntry get last => this;

  @override
  bool get isEmpty => true;

  // Returns true if there is at least one element in this collection.
  @override
  bool get isNotEmpty => false;

  @override
  int get length => 1;

  /// The uncompressed size, if it's a file
  int get size => 0;

  ArchiveEntry operator [](int index) => this;

  @override
  Iterator<ArchiveEntry> get iterator => [this].iterator;

  @override
  String toString() => fullPathName;

  InputStream? getContent() => null;

  Uint8List? readBytes() => null;
}

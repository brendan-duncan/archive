import 'dart:typed_data';

import 'archive_exception.dart';

class FileHandle {
  FileHandle(String path) {
    throw ArchiveException(
        'FileHandle is not supported on this platform $path.');
  }

  String get path => '';

  int get position => 0;

  int get length => 0;

  bool get isOpen => false;

  void setPosition(int p) {}

  bool open() => false;

  void close() {}

  int readInto(Uint8List buffer, [int? end]) => 0;
}

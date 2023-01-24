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

  Future<void> setPosition(int p) async {}

  Future<bool> open() async { return false; }

  Future<void> close() async {}

  Future<int> readInto(Uint8List buffer, [int? end]) async => 0;
}

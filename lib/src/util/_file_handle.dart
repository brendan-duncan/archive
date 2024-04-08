import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'archive_exception.dart';
import 'file_mode.dart';

class FileHandle extends AbstractFileHandle {
  FileHandle(String path, {FileMode mode = FileMode.read}) : super(mode) {
    throw ArchiveException(
        'FileHandle is not supported on this platform $path.');
  }

  String get path => '';

  @override
  int get position => 0;

  @override
  set position(int p) {}

  @override
  int get length => 0;

  @override
  bool get isOpen => false;

  @override
  bool open() => false;

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}

  @override
  int readInto(Uint8List buffer, [int? end]) => 0;

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {}
}

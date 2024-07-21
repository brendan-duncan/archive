import 'dart:typed_data';

import 'abstract_file_handle.dart';
import 'archive_exception.dart';
import 'file_access.dart';

class FileHandle extends AbstractFileHandle {
  FileHandle(String path, {FileAccess mode = FileAccess.read}) : super() {
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
  bool open({FileAccess mode = FileAccess.read}) => false;

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}

  @override
  int readInto(Uint8List buffer, [int? end]) => 0;

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {}
}

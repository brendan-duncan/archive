import 'dart:typed_data';

import 'file_access.dart';

/// Base class for MemoryFileHandle and FileHandle (dart:io).
abstract class AbstractFileHandle {
  FileAccess openMode;

  AbstractFileHandle(this.openMode);

  int get position;

  set position(int p);

  int get length;

  bool get isOpen;

  bool open() => false;

  Future<void> close();

  void closeSync();

  int readInto(Uint8List buffer, [int? end]);

  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
}

import 'dart:typed_data';

import 'file_access.dart';

/// Base class for MemoryFileHandle and FileHandle (dart:io).
abstract class AbstractFileHandle {
  AbstractFileHandle({FileAccess mode = FileAccess.read});

  int get position;

  set position(int p);

  int get length;

  bool get isOpen;

  bool open({FileAccess mode = FileAccess.read}) => false;

  Future<void> close();

  void closeSync();

  int readInto(Uint8List buffer, [int? end]);

  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
}

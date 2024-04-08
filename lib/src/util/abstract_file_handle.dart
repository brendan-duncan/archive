import 'dart:typed_data';

import 'file_mode.dart';

abstract class AbstractFileHandle {
  FileMode openMode;

  AbstractFileHandle(this.openMode);

  int get position;

  set position(int p);

  int get length;

  bool get isOpen;

  Future<void> close();

  void closeSync();

  int readInto(Uint8List buffer, [int? end]);

  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
}

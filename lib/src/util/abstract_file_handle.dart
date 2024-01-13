import 'dart:typed_data';

enum AbstractFileOpenMode {
  read,
  write,
}

abstract class AbstractFileHandle {
  AbstractFileOpenMode openMode;

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

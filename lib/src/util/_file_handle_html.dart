import 'dart:typed_data';
import 'abstract_file_handle.dart';
import 'file_access.dart';

class FileHandle extends AbstractFileHandle {
  FileHandle(String path, {FileAccess mode = FileAccess.read});

  /// The current read/write position pf the file.
  @override
  int get position => 0;

  /// Set the current read/write position of the file.
  @override
  set position(int p) {}

  /// The size of the file in bytes.
  @override
  int get length => 0;

  /// True if the file is currently open.
  @override
  bool get isOpen => false;

  /// Open the file with the given [mode], for either read or write.
  @override
  bool open({FileAccess mode = FileAccess.read}) => false;

  /// Close the file asynchronously.
  @override
  Future<void> close() async {}

  /// Close the file synchronously.
  @override
  void closeSync() {}

  /// Read from the file into the given [buffer].
  /// If [end] is omitted, it defaults to [buffer].length.
  @override
  int readInto(Uint8List buffer, [int? length]) => 0;

  /// Synchronously writes from a [buffer] to the file.
  /// Will read the buffer from index [start] to index [end].
  /// The [start] must be non-negative and no greater than [buffer].length.
  /// If [end] is omitted, it defaults to [buffer].length.
  /// Otherwise [end] must be no less than [start]
  /// and no greater than [buffer].length.
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {}
}

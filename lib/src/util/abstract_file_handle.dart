import 'dart:typed_data';

import 'file_access.dart';

/// Base class for [FileHandle] and [RamFileHandle].
/// Provides an interface for random access to the data of a file.
abstract class AbstractFileHandle {
  /// The current read/write position pf the file.
  int get position;

  /// Set the current read/write position of the file.
  set position(int p);

  /// The size of the file in bytes.
  int get length;

  /// True if the file is currently open.
  bool get isOpen;

  /// Open the file with the given [mode], for either read or write.
  bool open({FileAccess mode = FileAccess.read}) => false;

  /// Close the file asynchronously.
  Future<void> close();

  /// Close the file synchronously.
  void closeSync();

  /// Read from the file into the given [buffer].
  /// If [end] is omitted, it defaults to [buffer].length.
  int readInto(Uint8List buffer, [int? length]);

  /// Synchronously writes from a [buffer] to the file.
  /// Will read the buffer from index [start] to index [end].
  /// The [start] must be non-negative and no greater than [buffer].length.
  /// If [end] is omitted, it defaults to [buffer].length.
  /// Otherwise [end] must be no less than [start]
  /// and no greater than [buffer].length.
  void writeFromSync(List<int> buffer, [int start = 0, int? end]);
}

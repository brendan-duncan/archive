import 'dart:math' as math;
import 'dart:typed_data';

import 'abstract_file_handle.dart';

class RamFileHandle extends AbstractFileHandle {
  // ignore: deprecated_member_use_from_same_package
  final RamFileData _ramFileData;
  int _readPosition = 0;
  int _writePosition = 0;

  RamFileHandle._(super.openMode, this._ramFileData);

  /// Creates a writeable RamFileHandle
  factory RamFileHandle.asWritableRamBuffer({
    @Deprecated('Visible for testing only') int subListSize = 1024 * 1024,
  }) {
    // ignore: deprecated_member_use_from_same_package
    return RamFileHandle._(
      AbstractFileOpenMode.write,
      RamFileData.outputBuffer(subListSize: subListSize),
    );
  }

  /// Creates a read-only RamFileHandle from a RamFileData
  factory RamFileHandle.fromRamFileData(RamFileData ramFileData) {
    // ignore: deprecated_member_use_from_same_package
    return RamFileHandle._(AbstractFileOpenMode.read, ramFileData);
  }

  /// Creates a read-only RamFileHandle from a stream
  static Future<RamFileHandle> fromStream(
    Stream<Uint8List> stream,
    int fileLength,
  ) async {
    // ignore: deprecated_member_use_from_same_package
    return RamFileHandle.fromRamFileData(
      await RamFileData.fromStream(stream, fileLength),
    );
  }

  @override
  int get position => _readPosition;

  @override
  set position(int p) {
    if (p == _readPosition) {
      return;
    }
    _readPosition = p;
  }

  @override
  int get length => _ramFileData._length;

  @override
  bool get isOpen => true;

  @override
  Future<void> close() async {
    _readPosition = 0;
  }

  @override
  void closeSync() {
    _readPosition = 0;
  }

  @override
  int readInto(Uint8List buffer, [int? end]) {
    final size = _ramFileData.readIntoSync(
      buffer,
      _readPosition,
      end == null ? null : end + _readPosition,
    );
    _readPosition += size;
    return size;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    final int? usedEnd;
    if (end == null) {
      usedEnd = _writePosition + start + buffer.length;
    } else {
      usedEnd = _writePosition + end;
    }
    _ramFileData.writeFromSync(buffer, _writePosition + start, usedEnd);
    _writePosition = _ramFileData._length;
  }
}

class RamFileData {
  final List<List<int>> _content;
  final int _subListSize;
  int _length;
  int get length => _length;
  final bool _readOnly;

  @Deprecated('Visible for testing only')
  List<List<int>> get content => _content;

  RamFileData.outputBuffer({
    int subListSize = 1024 * 1024,
  })  : _content = <List<int>>[],
        _subListSize = subListSize,
        _length = 0,
        _readOnly = false;

  factory RamFileData.fromBytes(Uint8List bytes) {
    return RamFileData._([bytes], bytes.length, bytes.length, true);
  }

  static Future<RamFileData> fromStream(
    Stream<List<int>> source,
    int fileLength, {
    @Deprecated('Visible for testing only') int? subListMaxSize,
  }) async {
    final List<List<int>> list = <List<int>>[];
    int? usedSubListSize;
    bool listSizeChanged = false;
    await for (final List<int> intList in source) {
      if (usedSubListSize == null) {
        usedSubListSize = intList.length;
      } else if (listSizeChanged) {
        throw Exception(
          'RamFileData.fromStream: an non-ending entry of the stream has a different size from its predecessors.',
        );
      } else if (intList.length != usedSubListSize) {
        if (intList.length > usedSubListSize) {
          throw Exception(
            'RamFileData.fromStream: an entry of the stream had a larger size than its predecessors',
          );
        }
        listSizeChanged = true;
      }
      list.add(intList);
    }
    if (usedSubListSize == null) {
      throw Exception('RamFileData.fromStream: usedSubListSize is null');
    }
    return RamFileData._(list, usedSubListSize, fileLength, true);
  }

  RamFileData._(this._content, this._subListSize, this._length, this._readOnly);

  void clear() {
    _content.clear();
  }

  @Deprecated('Visible for testing only')
  List<int> readAsBytes() {
    return _content.expand<int>((List<int> x) => x).toList();
  }

  int readIntoSync(Uint8List buffer, int start, int? end) {
    final int usedEnd = math.min(end ?? (start + buffer.length), _length);
    int bufferStartWriteIndex = 0;
    int relativeStart;
    do {
      relativeStart = start + bufferStartWriteIndex;
      final int contentIndex = relativeStart ~/ _subListSize;
      if (contentIndex >= _content.length) {
        break;
      }
      final List<int> contentSubList = _content[contentIndex];
      final int subListStartIndex = relativeStart % _subListSize;
      final int dataLengthToCopy = math.min(
        usedEnd - relativeStart,
        _subListSize - subListStartIndex,
      );
      buffer.setRange(
        bufferStartWriteIndex,
        bufferStartWriteIndex + dataLengthToCopy,
        contentSubList.getRange(
          subListStartIndex,
          subListStartIndex + dataLengthToCopy,
        ),
      );
      bufferStartWriteIndex += dataLengthToCopy;
    } while (relativeStart < usedEnd);
    return usedEnd - start;
  }

  int writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if (_readOnly) {
      throw Exception('Cannot write to read-only RAM file data');
    }
    final int usedStart = start;
    final int usedEnd = end ?? (start + buffer.length);
    int bufferStartWriteIndex = 0;
    int relativeStart;
    do {
      relativeStart = usedStart + bufferStartWriteIndex;
      final int contentIndex = relativeStart ~/ _subListSize;
      while (contentIndex >= _content.length) {
        _content.add(Uint8List(_subListSize));
      }
      final List<int> contentSubList = _content[contentIndex];
      final int subListStartIndex = relativeStart % _subListSize;
      final int dataLengthToCopy = math.min(
        usedEnd - relativeStart,
        _subListSize - subListStartIndex,
      );
      contentSubList.setRange(
        subListStartIndex,
        subListStartIndex + dataLengthToCopy,
        buffer.getRange(
          bufferStartWriteIndex,
          bufferStartWriteIndex + dataLengthToCopy,
        ),
      );
      bufferStartWriteIndex += dataLengthToCopy;
    } while (relativeStart < usedEnd);
    _length = math.max(usedEnd, _length);
    return usedEnd - start;
  }
}

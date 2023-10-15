import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

abstract class AbstractFileHandle {
  int get position;
  set position(int p);
  int get length;
  bool get isOpen;
  Future<void> close();
  void open();
  int readInto(Uint8List buffer, [int? end]);
}

class FileHandle extends AbstractFileHandle {
  final String _path;
  RandomAccessFile? _file;
  int _position;
  late int _length;

  FileHandle(this._path)
      : _file = File(_path).openSync(),
        _position = 0 {
    _length = _file!.lengthSync();
  }

  String get path => _path;

  @override
  int get position => _position;

  @override
  set position(int p) {
    if (_file == null || p == _position) {
      return;
    }
    _position = p;
    _file!.setPositionSync(p);
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _file != null;

  @override
  Future<void> close() async {
    if (_file == null) {
      return;
    }
    var fp = _file;
    _file = null;
    _position = 0;
    await fp!.close();
  }

  @override
  void open() {
    if (_file != null) {
      return;
    }

    _file = File(_path).openSync();
    _position = 0;
  }

  @override
  int readInto(Uint8List buffer, [int? end]) {
    if (_file == null) {
      open();
    }
    final size = _file!.readIntoSync(buffer, 0, end);
    _position += size;
    return size;
  }
}

@Deprecated('Visible for testing only')
class RamFileData {
  final List<List<int>> _content;
  final int _subListSize;
  final int fileLength;

  @Deprecated('Visible for testing only')
  List<List<int>> get content => _content;

  @Deprecated('Visible for testing only')
  RamFileData.fromBytes(Uint8List source)
      : _content = <List<int>>[source],
        _subListSize = source.length,
        fileLength = source.length;

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
    return RamFileData._(list, usedSubListSize, fileLength);
  }

  RamFileData._(this._content, this._subListSize, this.fileLength);

  void clear() {
    _content.clear();
  }

  @Deprecated('Visible for testing only')
  List<int> readAsBytes() {
    return _content.expand<int>((List<int> x) => x).toList();
  }

  int readIntoSync(Uint8List buffer, int start, int? end) {
    final int usedEnd = math.min(end ?? (start + buffer.length), fileLength - 1);
    int bufferStartWriteIndex = 0;
    int relativeStart;
    do {
      relativeStart = start + bufferStartWriteIndex;
      final int contentIndex = relativeStart ~/ _subListSize;
      final List<int> contentSubList = _content[contentIndex];
      final int subListStartIndex = relativeStart % _subListSize;
      final int dataLengthToCopy = math.min(
        usedEnd - relativeStart,
        contentSubList.length - subListStartIndex,
      );
      buffer.setRange(
        bufferStartWriteIndex,
        bufferStartWriteIndex + dataLengthToCopy,
        contentSubList.getRange(subListStartIndex, subListStartIndex + dataLengthToCopy),
      );
      bufferStartWriteIndex += dataLengthToCopy;
    } while (relativeStart < usedEnd);
    return usedEnd - start;
  }
}

class RAMFileHandle extends AbstractFileHandle {
  // ignore: deprecated_member_use_from_same_package
  final RamFileData _ramFileData;
  int _position = 0;
  final int _length;

  RAMFileHandle._(this._ramFileData, this._length);

  static Future<RAMFileHandle> fromStream(Stream<Uint8List> stream, int fileLength) async {
    // ignore: deprecated_member_use_from_same_package
    return RAMFileHandle._(await RamFileData.fromStream(stream, fileLength), fileLength);
  }

  @override
  int get position => _position;

  @override
  set position(int p) {
    if (p == _position) {
      return;
    }
    _position = p;
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => true;

  @override
  Future<void> close() async {
    _ramFileData._content.clear();
    _position = 0;
  }

  @override
  void open() {
    _position = 0;
  }

  @override
  int readInto(Uint8List buffer, [int? end]) {
    final size = _ramFileData.readIntoSync(
      buffer,
      _position,
      end == null ? null : end + _position,
    );
    _position += size;
    return size;
  }
}

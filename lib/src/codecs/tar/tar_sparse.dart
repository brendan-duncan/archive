import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/byte_order.dart';
import '../../util/file_content.dart';
import '../../util/input_stream.dart';
import '../../util/output_file_stream.dart';
import '../../util/output_stream.dart';
import 'tar_file.dart';

const _maxValue = TarFile.maxNumericField;

class TarSparse {
  int realSize = -1;
  final regions = <(int, int)>[];
  bool extended = false;
  int extensionBlocks = 0;
  bool mapInData = false;
  int mapLength = 0;
  bool broken = false;

  var _count = -1;
  var _offset = -1;
  var _value = 0;
  var _line = 0;
  var _comment = false;
  var _scanned = 0;

  void add(int offset, int length) {
    if (length != 0) {
      regions.add((offset, length));
    }
  }

  bool? readMap(Uint8List chunk) {
    if (_scanned == 0) {
      regions.clear();
    }
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk[i];
      if (++_line > 100) {
        broken = true;
        return false;
      }
      if (_comment) {
        if (c == 0x0a) {
          _comment = false;
          _line = 0;
        }
      } else if (c == 0x23 && _line == 1) {
        _comment = true;
      } else if (c == 0x0a) {
        if (_scanned + i >= TarFile.maxMetadataSize) {
          throw ArchiveLimitException('Tar sparse map is larger than the '
              '${TarFile.maxMetadataSize} bytes allowed');
        }
        _line = 0;
        final value = _value;
        _value = 0;
        if (_count < 0) {
          _count = value;
        } else if (_offset < 0) {
          _offset = value;
          continue;
        } else {
          add(_offset, value);
          _offset = -1;
          _count--;
        }
        if (_count == 0) {
          mapLength = (_scanned + i + 512) ~/ 512 * 512;
          return true;
        }
      } else if (c >= 0x30 && c <= 0x39) {
        final digit = c - 0x30;
        _value = _value > (_maxValue - digit) ~/ 10
            ? _maxValue
            : _value * 10 + digit;
      } else {
        broken = true;
        return false;
      }
    }
    _scanned += chunk.length;
    return null;
  }

  bool fits(int dataSize) {
    if (broken || extended || (mapInData && mapLength == 0)) {
      return false;
    }
    if (regions.isEmpty && dataSize > mapLength) {
      regions.add((0, dataSize - mapLength));
    }
    var end = 0;
    var stored = 0;
    for (final (offset, length) in regions) {
      if (offset < end || length < 0 || length > realSize - offset) {
        return false;
      }
      end = offset + length;
      stored += length;
    }
    return stored == dataSize - mapLength;
  }
}

final _zeros = Uint8List(1 << 16);

class FileContentSparse extends FileContent {
  FileContentSparse(this._data, this._regions, int realSize)
      : length = _arrived(_data.length, _regions, realSize);

  static int _arrived(int stored, List<(int, int)> regions, int realSize) {
    var at = 0;
    for (final (offset, size) in regions) {
      if (size > stored - at) {
        return offset + (stored > at ? stored - at : 0);
      }
      at += size;
    }
    return realSize;
  }

  final InputStream _data;
  final List<(int, int)> _regions;
  late final List<int> _storedAt = () {
    var at = 0;
    return [
      for (final (_, size) in _regions) (at += size) - size,
    ];
  }();

  @override
  final int length;

  @override
  InputStream getStream({bool decompress = true}) =>
      _SparseInputStream(_data, _regions, _storedAt, 0, length);

  @override
  Uint8List readBytes() {
    final out = Uint8List(length);
    final stored = _data.length;
    var at = 0;
    for (final (offset, size) in _regions) {
      final take = size < stored - at ? size : stored - at;
      if (take > 0) {
        out.setRange(offset, offset + take,
            _data.subset(position: at, length: take).toUint8List());
      }
      if (take < size) {
        break;
      }
      at += size;
    }
    return out;
  }

  @override
  void write(OutputStream output) {
    var end = 0;
    void hole(int to) {
      if (output is OutputFileStream && end < to) {
        output.writeZeros(to - end);
        end = to;
        return;
      }
      while (end < to) {
        final n = to - end < _zeros.length ? to - end : _zeros.length;
        output.writeBytes(_zeros, length: n);
        end += n;
      }
    }

    final stored = _data.length;
    var at = 0;
    for (final (offset, size) in _regions) {
      hole(offset);
      final take = size < stored - at ? size : stored - at;
      if (take > 0) {
        output.writeStream(_data.subset(position: at, length: take));
      }
      if (take < size) {
        return;
      }
      at += size;
      end = offset + size;
    }
    hole(length);
  }

  @override
  void decompress(OutputStream output) => write(output);

  @override
  Future<void> close() async => _data.close();

  @override
  void closeSync() => _data.closeSync();
}

class _SparseInputStream extends InputStream {
  _SparseInputStream(
      this._data, this._regions, this._storedAt, this._start, this._end)
      : super(byteOrder: ByteOrder.littleEndian);

  final InputStream _data;
  final List<(int, int)> _regions;
  final List<int> _storedAt;
  final int _start;
  final int _end;
  int _position = 0;

  @override
  int get position => _position;

  @override
  set position(int v) => setPosition(v);

  @override
  int get length => _end - _start - _position;

  @override
  bool get isEOS => _position >= _end - _start;

  @override
  bool open() => _data.open();

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}

  @override
  void reset() => _position = 0;

  @override
  void setPosition(int v) => _position = v;

  @override
  void rewind([int length = 1]) => _position -= length;

  @override
  void skip(int length) => _position += length;

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) {
    final size = _end - _start;
    position ??= _position;
    length ??= size - position;
    final end = position + length < size ? position + length : size;
    return _SparseInputStream(
        _data, _regions, _storedAt, _start + position, _start + end);
  }

  @override
  int readByte() {
    final byte = Uint8List(1);
    readInto(byte, 0, 1);
    return byte[0];
  }

  @override
  int readInto(Uint8List into, int at, int count) {
    final left = length;
    final n = count < left ? count : (left > 0 ? left : 0);
    final from = _start + _position;
    final to = from + n;
    var first = 0;
    var last = _regions.length;
    while (first < last) {
      final mid = (first + last) >> 1;
      final (offset, size) = _regions[mid];
      if (offset + size <= from) {
        first = mid + 1;
      } else {
        last = mid;
      }
    }
    var cursor = from;
    for (var i = first; i < _regions.length; i++) {
      final (offset, size) = _regions[i];
      if (offset >= to) {
        break;
      }
      final lo = offset > cursor ? offset : cursor;
      final hi = offset + size < to ? offset + size : to;
      _zero(into, at + cursor - from, lo - cursor);
      if (lo < hi) {
        _data
            .subset(position: _storedAt[i] + lo - offset, length: hi - lo)
            .readInto(into, at + lo - from, hi - lo);
        cursor = hi;
      }
    }
    _zero(into, at + cursor - from, to - cursor);
    _position += n;
    return n;
  }

  static void _zero(Uint8List into, int at, int count) {
    while (count > 0) {
      final n = count < _zeros.length ? count : _zeros.length;
      into.setRange(at, at + n, _zeros);
      at += n;
      count -= n;
    }
  }

  @override
  Uint8List toUint8List() {
    final out = Uint8List(length > 0 ? length : 0);
    final held = _position;
    readInto(out, 0, out.length);
    _position = held;
    return out;
  }
}

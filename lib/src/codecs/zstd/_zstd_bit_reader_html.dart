import 'dart:typed_data';

/// Reads backwards from the last byte towards the first, most significant bit
/// first, ending on a marker 1 bit. Cold paths only
class ZstdBitReader {
  int container = 0;
  int consumed = 0;
  int position = 0;

  ByteData _view = ByteData(0);
  int _start = 0;
  int _end = 0;
  bool _overrun = false;

  /// Below 32 only for a stream shorter than four bytes, padded at the bottom
  int _bitLimit = 32;

  /// Check between symbols, not per read: one symbol spends at most 32 bits, so
  /// overrunning by one reads container zeros rather than leaving the buffer
  bool get isOverrun => _overrun || consumed > _bitLimit;

  bool get isAtEnd => !_overrun && position == _start && consumed == _bitLimit;

  /// False when the stream is empty or ends in a zero byte, which the format
  /// forbids and which leaves no defined first bit
  bool setStream(Uint8List data, int start, int length) {
    if (length <= 0 || start < 0 || start + length > data.length) {
      return false;
    }
    final last = data[start + length - 1];
    if (last == 0) {
      return false;
    }

    _view = ByteData.sublistView(data);
    _start = start;
    _end = start + length;
    _overrun = false;

    if (length >= 4) {
      position = _end - 4;
      container = _view.getUint32(position, Endian.little);
      _bitLimit = 32;
    } else {
      // The last byte goes to the top byte, as getUint32 above reads it
      position = start;
      var value = 0;
      for (var i = length - 1; i >= 0; i--) {
        value = (value << 8) | data[start + i];
      }
      container = (value << ((4 - length) << 3)) >>> 0;
      _bitLimit = length << 3;
    }

    consumed = 8 - _highestBit(last);
    return true;
  }

  /// [count] in 1 to 24, since a shift of 32 is not portable
  int peek(int count) => ((container << consumed) >>> 0) >>> (32 - count);

  void skip(int count) {
    consumed += count;
  }

  int read(int count) {
    if (count == 0) {
      return 0;
    }
    final value = peek(count);
    consumed += count;
    return value;
  }

  void reload() {
    if (consumed > _bitLimit) {
      _overrun = true;
      consumed = _bitLimit;
      return;
    }
    if (position == _start) {
      return;
    }

    final step = consumed >> 3;
    if (position - step < _start) {
      // Bits spent below _start stay counted, so consumed keeps tracking
      consumed -= (position - _start) << 3;
      position = _start;
    } else {
      position -= step;
      consumed &= 7;
    }
    container = _view.getUint32(position, Endian.little);
  }

  static int _highestBit(int value) {
    var v = value;
    var bit = 0;
    if (v >= 1 << 4) {
      v >>= 4;
      bit += 4;
    }
    if (v >= 1 << 2) {
      v >>= 2;
      bit += 2;
    }
    if (v >= 1 << 1) {
      bit += 1;
    }
    return bit;
  }
}

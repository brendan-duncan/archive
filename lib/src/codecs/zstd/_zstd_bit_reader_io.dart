import 'dart:typed_data';

/// Reads backwards from the last byte towards the first, most significant bit
/// first, ending on a marker 1 bit. Cold paths only: the hot loops hold the
/// same three values in locals, so they are public fields here
class ZstdBitReader {
  int container = 0;
  int consumed = 0;
  int position = 0;

  ByteData _view = ByteData(0);
  int _start = 0;
  int _end = 0;
  bool _overrun = false;

  /// Below 64 only for a stream shorter than eight bytes, padded at the bottom
  int _bitLimit = 64;

  /// Check between symbols, not per read: one symbol spends at most 64 bits, so
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

    if (length >= 8) {
      position = _end - 8;
      container = _view.getUint64(position, Endian.little);
      _bitLimit = 64;
    } else {
      // The last byte goes to the top byte, as getUint64 above reads it
      position = start;
      var value = 0;
      for (var i = length - 1; i >= 0; i--) {
        value = (value << 8) | data[start + i];
      }
      container = value << ((8 - length) * 8);
      _bitLimit = length << 3;
    }

    // The marker counts as read, so an exhausted stream ends on `_bitLimit`
    consumed = 8 - _highestBit(last);
    return true;
  }

  /// [count] in 1 to 56, since a shift of 64 is not portable
  @pragma('vm:prefer-inline')
  int peek(int count) => (container << consumed) >>> (64 - count);

  @pragma('vm:prefer-inline')
  void skip(int count) {
    consumed += count;
  }

  @pragma('vm:prefer-inline')
  int read(int count) {
    if (count == 0) {
      return 0;
    }
    final value = peek(count);
    consumed += count;
    return value;
  }

  /// Leaves at least 57 bits in the container
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
      // Bits spent below _start stay counted so consumed keeps tracking the
      // real position in the stream
      consumed -= (position - _start) << 3;
      position = _start;
    } else {
      position -= step;
      consumed &= 7;
    }
    container = _view.getUint64(position, Endian.little);
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

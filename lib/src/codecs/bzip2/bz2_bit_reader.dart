import '../../util/input_stream.dart';

/// Internal class used by [BZip2Decoder]
class Bz2BitReader {
  InputStream input;

  /// With [readPastEnd] a read past the end of [input] reads from it rather
  /// than returning zeros. The chunked decoder needs that, since the stream it
  /// reads throws there, and the throw ends a trial decode of a block that has
  /// not arrived in full.
  Bz2BitReader(this.input, {this.readPastEnd = false});

  final bool readPastEnd;

  int readByte() => readBits(8);

  /// Remaining amount of bits of the current byte are not read yet
  int get bitsLeft => _bitPos;

  /// Without this flag, reading from a file would return zeros and reading
  /// from memory would throw. With it, both cases simply fail the same way
  bool get overrun => _overrun;

  int _nextByte() {
    if (!readPastEnd && input.isEOS) {
      _overrun = true;
      return 0;
    }
    return input.readByte();
  }

  /// Read a number of bits from the input stream.
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    if (_bitPos == 0) {
      _bitPos = 8;
      _bitBuffer = _nextByte();
    }

    var value = 0;

    while (numBits > _bitPos) {
      value = (value << _bitPos) + (_bitBuffer & _bitMask[_bitPos]);
      numBits -= _bitPos;
      _bitPos = 8;
      _bitBuffer = _nextByte();
    }

    if (numBits > 0) {
      if (_bitPos == 0) {
        _bitPos = 8;
        _bitBuffer = _nextByte();
      }

      value = (value << numBits) +
          (_bitBuffer >> (_bitPos - numBits) & _bitMask[numBits]);

      _bitPos -= numBits;
    }

    return value;
  }

  int _bitBuffer = 0;
  int _bitPos = 0;
  var _overrun = false;

  static const List<int> _bitMask = [0, 1, 3, 7, 15, 31, 63, 127, 255];
}

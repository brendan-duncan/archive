import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';

const _maskToBitNumber = [0, 1, 2, 2, 3, 3, 3, 3];
const _maskArray = [0xffffffff, 0xffffff, 0xffff, 0xff];

// Bit i is set when a previous mask value of i allows a conversion. Replaces
// a lookup in a list of booleans on the hot path.
const _allowedStatusMask = 0x17;

@pragma('vm:prefer-inline')
bool _testMsByte(int b) => b == 0x00 || b == 0xff;

/// Applies the x86 BCJ filter to [buffer] in the decode direction, in place.
///
/// [startOffset] is the start offset property from the block header, which is
/// zero unless the encoder was given an explicit one.
///
/// The filter state never crosses an xz block boundary, so a whole block can
/// be passed in a single call.
int bcjX86Decode(Uint8List buffer, [int startOffset = 0]) =>
    _decode(buffer, startOffset, 0, startOffset - 5).$1;

class BcjX86Decoder {
  BcjX86Decoder([int startOffset = 0])
      : _nowPos = startOffset,
        _prevPos = startOffset - 5;

  int _nowPos;
  int _prevPos;
  var _prevMask = 0;

  // E8 or E9 operand may continue in next piece, so up to 4 trailing bytes
  // stay unfiltered and are left out of returned count
  int decode(Uint8List buffer) {
    final (done, prevMask, prevPos) =
        _decode(buffer, _nowPos, _prevMask, _prevPos);
    _prevMask = prevMask;
    _prevPos = prevPos;
    _nowPos += done;
    return done;
  }
}

// Loop stays outside BcjX86Decoder: with `this` live across it, 2 spilled
// values were reloaded per byte, 6% more instructions and 1% more cycles
// on enwik8
@pragma('vm:unsafe:no-bounds-checks')
(int, int, int) _decode(
    Uint8List buffer, int nowPos, int prevMask, int prevPos) {
  if (buffer.length < 5) {
    return (0, prevMask, prevPos);
  }

  final limit = buffer.length - 5;
  var bufferPos = 0;

  while (bufferPos <= limit) {
    var b = buffer[bufferPos];
    if (b & 0xfe != 0xe8) {
      bufferPos++;
      continue;
    }

    final offset = nowPos + bufferPos - prevPos;
    prevPos = nowPos + bufferPos;

    if (offset > 5) {
      prevMask = 0;
    } else {
      for (var i = 0; i < offset; i++) {
        prevMask &= 0x77;
        prevMask = (prevMask << 1) & 0xff;
      }
    }

    b = buffer[bufferPos + 4];
    if (_testMsByte(b) &&
        (_allowedStatusMask >> ((prevMask >> 1) & 0x7)) & 1 != 0 &&
        (prevMask >> 1) < 0x10) {
      var src = (b << 24) |
          (buffer[bufferPos + 3] << 16) |
          (buffer[bufferPos + 2] << 8) |
          buffer[bufferPos + 1];

      int dest;
      while (true) {
        dest = (src - (nowPos + bufferPos + 5)) & 0xffffffff;
        if (prevMask == 0) {
          break;
        }
        final i = _maskToBitNumber[prevMask >> 1];
        b = (dest >> (24 - i * 8)) & 0xff;
        if (!_testMsByte(b)) {
          break;
        }
        src = (dest ^ _maskArray[i]) & 0xffffffff;
      }

      buffer[bufferPos + 4] = (~(((dest >> 24) & 1) - 1)) & 0xff;
      buffer[bufferPos + 3] = (dest >> 16) & 0xff;
      buffer[bufferPos + 2] = (dest >> 8) & 0xff;
      buffer[bufferPos + 1] = dest & 0xff;
      bufferPos += 5;
      prevMask = 0;
    } else {
      prevMask |= 0x01;
      if (_testMsByte(b)) {
        prevMask |= 0x10;
      }
      bufferPos++;
    }
  }

  return (bufferPos, prevMask, prevPos);
}

class BcjX86OutputStream extends OutputStream {
  BcjX86OutputStream(this.output, [int startOffset = 0])
      : _filter = BcjX86Decoder(startOffset),
        super(byteOrder: output.byteOrder);

  final OutputStream output;
  final BcjX86Decoder _filter;
  var _tail = Uint8List(0);
  var _written = 0;

  @override
  int get length => _written;

  // LZMA writes view of its dictionary, and later matches read those bytes,
  // so we filter copy
  @override
  void writeRange(Uint8List bytes, int start, int end) {
    if (end <= start) {
      return;
    }
    final held = _tail.length;
    final piece = Uint8List(held + end - start)
      ..setRange(0, held, _tail)
      ..setRange(held, held + end - start, bytes, start);
    _written += end - start;
    final done = _filter.decode(piece);
    output.writeRange(piece, 0, done);
    _tail = Uint8List.fromList(Uint8List.sublistView(piece, done));
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) => writeRange(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      0,
      length ?? bytes.length);

  @override
  void writeByte(int value) => writeRange(Uint8List(1)..[0] = value, 0, 1);

  @override
  void writeStream(InputStream stream) {
    final bytes = stream.toUint8List();
    writeRange(bytes, 0, bytes.length);
  }

  /// Up to 4 held bytes are lost unless this runs at end of block
  void finish() {
    output.writeRange(_tail, 0, _tail.length);
    _tail = Uint8List(0);
  }

  @override
  void flush() => output.flush();

  @override
  void clear() {
    _tail = Uint8List(0);
    _written = 0;
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('filtered output cannot be read back');
}

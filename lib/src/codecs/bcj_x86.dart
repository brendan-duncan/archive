import 'dart:typed_data';

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
@pragma('vm:unsafe:no-bounds-checks')
void bcjX86Decode(Uint8List buffer, [int startOffset = 0]) {
  if (buffer.length < 5) {
    return;
  }

  final nowPos = startOffset;
  var prevMask = 0;
  var prevPos = nowPos - 5;
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
}

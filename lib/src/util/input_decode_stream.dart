import 'dart:math';
import 'dart:typed_data';

import 'archive_exception.dart';
import 'byte_order.dart';
import 'input_stream.dart';
import 'output_stream.dart';

/// Decodes an input a chunk at a time, for [InputDecodeStream].
///
/// The decoders implement this for their `decodeLazy` methods, so that a
/// stream can pull decoded data out of them as it is read rather than having
/// them write everything out in one call.
abstract class ChunkDecoder {
  /// How many bytes of its own output the decoder refers back to, which
  /// [InputDecodeStream] keeps available behind the write position. Zero for
  /// a decoder that keeps its own history.
  int get history => 0;

  /// Decodes the next chunk of input into [output].
  ///
  /// Returns false once there is nothing more to decode, in which case the
  /// call may still have written the last of the output. A call may also
  /// write nothing and return true, when the input it consumed did not
  /// complete a chunk. Throws an [ArchiveException] if the input is malformed
  /// or truncated.
  bool decodeChunk(OutputStream output);
}

/// An [InputStream] over data that is decoded from another stream as it is
/// read.
///
/// Only a window of the decoded data is held in memory: what has been decoded
/// but not yet read, plus a little behind the read position. That makes it
/// possible to pass a 3 GB `.tar.gz` through a tar decoder in a few megabytes
/// of memory, where decoding it to an output stream first would need a temp
/// file or all of it in memory.
///
/// The price is that the stream is read forwards. [readBytes] and [subset]
/// hand out views that read their part of the data when they are read, so an
/// entry's content can be consumed after its header was parsed, but once the
/// read position has moved on past something and the window has slid over
/// it, reading it throws an [ArchiveException]. Decode to an
/// [OutputStream] where random access is needed.
///
/// [length] on the stream itself has to decode everything that remains in
/// order to count it, which holds it all in the window. Loop on [isEOS]
/// instead, or read a [subset] of known length. The views returned by
/// [readBytes] and [subset] know their length.
class InputDecodeStream extends InputStream {
  final _DecodeWindow _window;
  // Where this stream starts in the decoded data, and how long it is, which
  // is null for the stream over all of it.
  final int _offset;
  final int? _length;
  int _position = 0;

  /// Creates a stream over the data [decoder] produces.
  ///
  /// [keepBehind] is how many bytes behind the read position stay readable,
  /// for a consumer that rewinds a little. The window holds more when the
  /// decoder writes faster than the consumer reads, but no less.
  InputDecodeStream(ChunkDecoder decoder,
      {ByteOrder byteOrder = ByteOrder.littleEndian, int keepBehind = 0})
      : _window = _DecodeWindow(decoder, keepBehind),
        _offset = 0,
        _length = null,
        super(byteOrder: byteOrder);

  InputDecodeStream._view(InputDecodeStream other, int position, int? length)
      : _window = other._window,
        _offset = other._offset + position,
        _length = length,
        super(byteOrder: other.byteOrder);

  int get _absolute => _offset + _position;

  @override
  int get position => _position;

  @override
  set position(int v) => _position = v;

  @override
  void setPosition(int v) => _position = v;

  @override
  void reset() => _position = 0;

  @override
  void rewind([int length = 1]) {
    _position = max(0, _position - length);
  }

  @override
  void skip(int length) {
    _position += length;
  }

  /// The bytes left in this stream.
  ///
  /// For a view from [readBytes] or [subset] this is what it was given, less
  /// what has been read, even if the decoded data turns out to end sooner.
  /// For the stream over all of the data it is the number of bytes still to
  /// come, which the stream has to decode to count: see the class note.
  @override
  int get length {
    final length = _length;
    if (length != null) {
      return max(0, length - _position);
    }
    return _window.remainingFrom(_absolute);
  }

  @override
  bool get isEOS {
    final length = _length;
    if (length != null && _position >= length) {
      return true;
    }
    return _window.isEnd(_absolute);
  }

  @override
  bool open() => true;

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    // Views come and go, as every entry of an archive is one; only the stream
    // over the whole of the data owns the window.
    if (_offset == 0 && _length == null) {
      _window.release();
    }
  }

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) {
    position ??= _position;
    final own = _length;
    if (own != null) {
      final available = max(0, own - position);
      length = length == null ? available : min(length, available);
    }
    return InputDecodeStream._view(this, position, length);
  }

  @override
  int readByte() {
    if (isEOS) {
      return 0;
    }
    final b = _window.byteAt(_absolute);
    _position++;
    return b;
  }

  @override
  InputStream readBytes(int count) {
    final own = _length;
    if (own != null) {
      count = max(0, min(count, own - _position));
    }
    // A view, not a copy: nothing is decoded until the view is read.
    final bytes = InputDecodeStream._view(this, _position, count);
    _position += count;
    return bytes;
  }

  @override
  Uint8List toUint8List() {
    final own = _length;
    if (own != null) {
      return _window.read(_absolute, max(0, own - _position));
    }
    return _window.readToEnd(_absolute);
  }
}

/// The decoded data held between the decoder and the readers. It is the
/// [OutputStream] the decoder writes into, and slides forward as the readers
/// move on.
class _DecodeWindow extends OutputStream {
  final ChunkDecoder _decoder;
  final int _keepBehind;
  Uint8List _buffer = Uint8List(_initialSize);
  // The position in the decoded data of the first byte in the buffer, and
  // how many bytes the buffer holds.
  int _start = 0;
  int _end = 0;
  // The position the read in progress asked for. Nothing before it, less
  // [_keepBehind], has to be kept when the buffer is compacted.
  int _reading = 0;
  bool _done = false;

  static const _initialSize = 64 * 1024;

  _DecodeWindow(this._decoder, this._keepBehind)
      : super(byteOrder: ByteOrder.littleEndian);

  // The position just past the last decoded byte.
  int get _limit => _start + _end;

  /// As an output stream: how much the decoder has written in all.
  @override
  int get length => _limit;

  // Decodes until the data covers [pos] through [pos] + [count], or ends.
  void _ensure(int pos, int count) {
    if (pos < _start) {
      throw ArchiveException(
          'Position $pos of the decoded data has already been read past, '
          'only the last ${_end} bytes from $_start are still held');
    }
    _reading = pos;
    while (!_done && _limit < pos + count) {
      if (!_decoder.decodeChunk(this)) {
        _done = true;
      }
    }
  }

  int byteAt(int pos) {
    _ensure(pos, 1);
    if (pos >= _limit) {
      return 0;
    }
    return _buffer[pos - _start];
  }

  bool isEnd(int pos) {
    _ensure(pos, 1);
    return pos >= _limit;
  }

  Uint8List read(int pos, int count) {
    _ensure(pos, count);
    final n = max(0, min(count, _limit - pos));
    return _buffer.sublist(pos - _start, pos - _start + n);
  }

  Uint8List readToEnd(int pos) => read(pos, remainingFrom(pos));

  int remainingFrom(int pos) {
    _ensure(pos, 1 << 50);
    return max(0, _limit - pos);
  }

  void release() {
    _buffer = Uint8List(0);
    _start = _limit;
    _end = 0;
    _done = true;
  }

  // Makes room for [n] more bytes, dropping what no reader needs and growing
  // the buffer if that is not enough.
  void _reserve(int n) {
    if (_end + n <= _buffer.length) {
      return;
    }
    final keepFrom =
        max(_start, min(_reading - _keepBehind, _limit - _decoder.history));
    final drop = keepFrom - _start;
    if (drop > 0) {
      _buffer.setRange(0, _end - drop, _buffer, drop);
      _end -= drop;
      _start += drop;
    }
    if (_end + n > _buffer.length) {
      final grown = Uint8List(max(_buffer.length * 2, _end + n));
      grown.setRange(0, _end, _buffer);
      _buffer = grown;
    }
  }

  @override
  void writeByte(int value) {
    if (_end == _buffer.length) {
      _reserve(1);
    }
    _buffer[_end++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    _reserve(length);
    _buffer.setRange(_end, _end + length, bytes);
    _end += length;
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    final src = _end - distance;
    if (src < 0) {
      throw ArchiveException('Back reference before the start of the data');
    }
    if (distance >= count) {
      _buffer.setRange(_end, _end + count, _buffer, src);
    } else {
      // Overlapping, so byte by byte to repeat the pattern.
      var s = src;
      var d = _end;
      final end = _end + count;
      while (d < end) {
        _buffer[d++] = _buffer[s++];
      }
    }
    _end += count;
  }

  /// Bytes the decoder wrote, by position relative to the end of its output
  /// when negative.
  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) {
      start = _limit + start;
    }
    if (end == null) {
      end = _limit;
    } else if (end < 0) {
      end = _limit + end;
    }
    if (start < _start) {
      throw ArchiveException('Position $start of the decoded data is no '
          'longer held');
    }
    return _buffer.sublist(start - _start, end - _start);
  }

  @override
  void flush() {}

  @override
  void clear() {}
}

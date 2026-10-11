import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'byte_order.dart';
import 'decode_guard.dart';
import 'input_decode_stream.dart';
import 'input_stream.dart';
import 'output_memory_stream.dart';
import 'output_stream.dart';

/// A codec that gets bytes as they arrive.
///
/// The decoders in this package pull: they ask their input for the next field
/// and the input blocks until it has it. A `Stream` cannot be read that way, so
/// this turns the loop around. A subclass keeps its position in fields rather
/// than on the stack, reads whatever has arrived in [step], and returns as soon
/// as a field is short. The next arrival resumes the parse.
///
/// The base handles everything not format-specific: it buffers bytes that
/// arrived and were not read, passes the incoming buffer to the parse when
/// nothing is buffered, and decides what a failure means afterwards.
abstract class ChunkedSink extends ByteConversionSink {
  /// Where the result goes, one piece at a time
  final Sink<List<int>> output;

  ChunkedSink(this.output);

  /// Bytes that have arrived and not been read. It holds one field, or one
  /// unit of the format, never everything that has come past
  Uint8List _carry = Uint8List(0);

  /// The buffer this sink owns. [_carry] is the incoming piece while a call is
  /// running and this one between calls
  Uint8List _owned = Uint8List(0);
  int _at = 0;
  int _end = 0;

  var _closed = false;
  Object? _failure;

  /// Bytes read so far. A format measures its padding and its own lengths
  /// against this
  var consumed = 0;

  /// When set, [step] returns after one unit of the format, a block or a
  /// chunk. [ChunkedSinkDecoder] sets it, since an input of a few bytes can
  /// decode to gigabytes in one call otherwise
  var unitAtATime = false;

  /// Reads what has arrived and returns at the first field that is not all
  /// here yet. Called again with more bytes behind it
  void step();

  /// What the format needs before the input may end. Called once, after the
  /// last [step], and only when nothing has failed
  void finish();

  /// How many bytes have arrived and not been read
  int get available => _end - _at;

  /// The next [count] bytes without copying them. Only valid until the call
  /// that reads them returns, since it may be a view of the incoming piece
  Uint8List view(int count) => Uint8List.sublistView(_carry, _at, _at + count);

  /// Marks [count] bytes as read
  void skip(int count) {
    _at += count;
    consumed += count;
  }

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  /// Takes part of a buffer without creating a view of it first, as
  /// `ByteConversionSink` allows
  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    RangeError.checkValidRange(start, end, chunk.length);
    // One copy, not two. Whatever the parse does not read is moved to our own
    // buffer before this returns, so this copy is safe to keep
    _add(chunk is Uint8List
        ? Uint8List.sublistView(chunk, start, end)
        : (Uint8List(end - start)..setRange(0, end - start, chunk, start)));
    if (isLast) {
      close();
    }
  }

  void _add(Uint8List bytes) {
    if (_closed) {
      throw StateError('Cannot add to a closed sink');
    }
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    if (bytes.isEmpty) {
      return;
    }
    if (_at == _end) {
      // Nothing is held, so the parse reads out of what arrived rather than
      // out of a copy of it. The incoming buffer may be reused the moment this
      // returns. So we keep whatever the parse did not reach
      _carry = bytes;
      _at = 0;
      _end = bytes.length;
      try {
        _guarded(step);
      } finally {
        _keepRest();
      }
      return;
    }
    _append(bytes);
    _guarded(step);
  }

  /// Runs the parse again over what is already held, for a subclass that
  /// stopped on something other than a short field
  void resume() {
    if (_closed) {
      return;
    }
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    _guarded(step);
  }

  /// Closes [output] only if the input ended cleanly. On a failed parse it
  /// stays open, the same as `gzip.decoder` and `zlib.decoder` in `dart:io`,
  /// so you have to close your own file or socket. The first close after a
  /// failure reports it, and a close after that returns without doing anything,
  /// as `dart:io` does. `add` after a failure reports it every time
  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    _guarded(step);
    _guarded(finish);
    output.close();
  }

  /// Runs a piece of the parse and remembers a failure, so that the next call
  /// reports the same one rather than reading what follows it as if nothing
  /// had happened. A codec's core throws whatever error it hits on corrupt
  /// data, and here that becomes one kind of failure
  void _guarded(void Function() body) {
    try {
      body();
    } catch (error) {
      _failure ??= archiveError(error);
      throw _failure!;
    }
  }

  void _append(Uint8List chunk) {
    final held = _end - _at;
    final need = held + chunk.length;
    if (need > _owned.length) {
      var size = _owned.isEmpty ? 1 << 16 : _owned.length;
      while (size < need) {
        size <<= 1;
      }
      final next = Uint8List(size);
      next.setRange(0, held, _carry, _at);
      _owned = next;
    } else {
      _owned.setRange(0, held, _carry, _at);
    }
    _carry = _owned;
    _at = 0;
    _end = held;
    _carry.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Moves what the parse did not reach into this sink's own buffer, so that
  /// no view of the incoming piece outlives the call
  void _keepRest() {
    final rest = _end - _at;
    if (rest > _owned.length) {
      var size = _owned.isEmpty ? 1 << 16 : _owned.length;
      while (size < rest) {
        size <<= 1;
      }
      _owned = Uint8List(size);
    }
    if (rest > 0) {
      _owned.setRange(0, rest, _carry, _at);
    }
    _carry = _owned;
    _at = 0;
    _end = rest;
  }
}

/// A `Converter` over a [ChunkedSink]. Whole input conversion goes through the
/// chunked path. `ZLibDecoder` does the same, so there is one behaviour rather
/// than two
abstract class ChunkedConverter extends Converter<List<int>, List<int>> {
  const ChunkedConverter();

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink);

  @override
  List<int> convert(List<int> input) {
    final held = _Collected();
    startChunkedConversion(held)
      ..add(input)
      ..close();
    return held.bytes;
  }

  /// A stream hears a failure once. The sink throws it again on every later
  /// call, so the input after it is dropped here, as gzip and zlib in dart:io
  /// drop it
  @override
  Stream<List<int>> bind(Stream<List<int>> stream) =>
      Stream<List<int>>.eventTransformed(
          stream, (sink) => _FailOnce(startChunkedConversion(sink), sink));
}

/// [FailOnceSink] cannot replace this class. Its `add` calls addSlice, and
/// default ByteConversionSink.addSlice copies each chunk, so ChunkedConverter
/// subclasses outside this package would receive copies
class _FailOnce implements EventSink<List<int>> {
  final ByteConversionSink _input;
  final EventSink<List<int>> _output;
  var _failed = false;

  _FailOnce(this._input, this._output);

  @override
  void add(List<int> data) {
    if (_failed) {
      return;
    }
    try {
      _input.add(data);
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);

  @override
  void close() {
    if (_failed) {
      return;
    }
    try {
      _input.close();
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }
}

/// Lets [InputDecodeStream] pull from a [ChunkedSink], which is pushed to
class ChunkedSinkDecoder implements ChunkDecoder {
  final InputStream _input;
  final _sink = _OutputStreamSink();
  late final ChunkedSink _decoder;
  final _buffer = Uint8List(1 << 16);
  var _done = false;

  ChunkedSinkDecoder(
      this._input, ChunkedSink Function(Sink<List<int>> output) create) {
    _decoder = create(_sink)..unitAtATime = true;
  }

  @override
  int get history => 0;

  @override
  bool decodeChunk(OutputStream output) {
    if (_done) {
      return false;
    }
    _sink.target = output;
    if (_decoder.available > 0) {
      final consumed = _decoder.consumed;
      _decoder.resume();
      if (_decoder.consumed != consumed) {
        return true;
      }
    }
    if (_input.isEOS) {
      _done = true;
      _decoder.close();
      return false;
    }
    final want =
        _input.length < _buffer.length ? _input.length : _buffer.length;
    final got = _input.readInto(_buffer, 0, want);
    _decoder.addSlice(_buffer, 0, got, false);
    return true;
  }
}

class _OutputStreamSink implements Sink<List<int>> {
  late OutputStream target;

  @override
  void add(List<int> data) => target.writeBytes(data);

  @override
  void close() {}
}

class FailOnceSink extends ByteConversionSink {
  final ByteConversionSink _input;
  var _failed = false;

  FailOnceSink(this._input);

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_failed) {
      return;
    }
    try {
      _input.addSlice(chunk, start, end, isLast);
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  @override
  void close() {
    if (_failed) {
      return;
    }
    try {
      _input.close();
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }
}

class _Collected implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {}

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

/// Under the block every codec here gathers into
const _streamPiece = 1 << 16;

/// The output side of a chunked codec: what a codec's core writes into an
/// `OutputStream`, sent to a `Sink` piece by piece.
///
/// Every range is copied on the way out. The core writes ranges of a buffer it
/// keeps using, so a sink that held a view of one would see it change
class SinkOutputStream extends OutputStream {
  final Sink<List<int>> sink;

  SinkOutputStream(this.sink) : super(byteOrder: ByteOrder.littleEndian);

  /// Written since the last [reset]. A format compares this against the length
  /// it declared
  var written = 0;

  /// Where the bytes go instead of the sink, for the stretch a filter has to
  /// read back before anything may be sent
  OutputMemoryStream? get divert => _divert;
  OutputMemoryStream? _divert;

  set divert(OutputMemoryStream? held) {
    // What is queued belongs in front of what is about to be diverted
    _drain();
    _divert = held;
  }

  /// Small writes are gathered here before they are sent: a bit writer sends
  /// single bytes, and a file or socket sink costs a call per write
  final Uint8List _buffer = Uint8List(_streamPiece);
  int _queued = 0;

  /// Called with every piece as it is written, so a checksum is updated
  /// incrementally without holding the data
  void Function(Uint8List piece)? watch;

  void reset() {
    written = 0;
  }

  @override
  int get length => written;

  @override
  void writeRange(Uint8List bytes, int start, int end) =>
      _emit(Uint8List.sublistView(bytes, start, end));

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _emit(bytes is Uint8List
        ? Uint8List.sublistView(bytes, 0, count)
        : Uint8List.fromList(bytes.sublist(0, count)));
  }

  @override
  void writeByte(int value) {
    // bzip2 writes a byte at a time. Two lists per byte made its streamed
    // decode 24% slower. This does what _emit does with a one byte piece
    final held = _divert;
    if (watch != null) {
      _emit(Uint8List.fromList([value]));
    } else if (held != null) {
      written++;
      held.writeByte(value);
    } else {
      written++;
      _buffer[_queued++] = value;
      if (_queued == _streamPiece) {
        _drain();
      }
    }
  }

  /// A piece at a time rather than one buffer, since `toUint8List` on a file
  /// reads the whole remainder. The read position ends where it started
  @override
  void writeStream(InputStream stream) {
    final held = stream.position;
    final buffer = Uint8List(_streamPiece);
    try {
      while (!stream.isEOS) {
        final got = stream.readInto(buffer, 0, buffer.length);
        if (got <= 0) {
          break;
        }
        _emit(Uint8List.sublistView(buffer, 0, got));
      }
    } finally {
      stream.setPosition(held);
    }
  }

  void _emit(Uint8List piece) {
    if (piece.isEmpty) {
      return;
    }
    written += piece.length;
    watch?.call(piece);
    final held = _divert;
    if (held != null) {
      held.writeBytes(piece);
      return;
    }
    // A range the core wrote can be megabytes, and a sink given it in one go
    // has no way to hold the codec back while it deals with it
    if (piece.length >= _streamPiece) {
      _drain();
      for (var at = 0; at < piece.length; at += _streamPiece) {
        final end =
            at + _streamPiece < piece.length ? at + _streamPiece : piece.length;
        sink.add(Uint8List.fromList(Uint8List.sublistView(piece, at, end)));
      }
      return;
    }
    var at = 0;
    while (at < piece.length) {
      var take = _streamPiece - _queued;
      if (take > piece.length - at) {
        take = piece.length - at;
      }
      _buffer.setRange(_queued, _queued + take, piece, at);
      _queued += take;
      at += take;
      if (_queued == _streamPiece) {
        _drain();
      }
    }
  }

  void _drain() {
    if (_queued == 0) {
      return;
    }
    sink.add(Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _queued)));
    _queued = 0;
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('a streamed result cannot be read back');

  /// Drops the count and anything still buffered. Bytes already sent to the
  /// sink cannot be taken back.
  ///
  /// The other outputs drop too: `OutputMemoryStream.clear` sets its
  /// length to zero and `OutputFileStream.clear` closes the file. `dart:io` has
  /// no such method to follow. Nothing in the package calls this on a sink:
  /// `Inflate` clears only an [OutputMemoryStream], and `Deflate` clears from
  /// `takeBytes`, which no streamed path reaches
  @override
  void clear() {
    written = 0;
    _queued = 0;
  }

  /// Sends whatever is queued. Every codec calls this when it is done, which
  /// makes the gathering safe
  @override
  void flush() => _drain();

  /// Sends whatever is queued, then closes [sink]. `OutputFileStream` flushes
  /// before it closes its file, and in `dart:io` closing the sink of
  /// `zlib.encoder.startChunkedConversion` closes that sink too. A close after
  /// a close does nothing, as `dart:io` does
  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    if (!_open) {
      return;
    }
    _open = false;
    _drain();
    sink.close();
  }

  @override
  bool get isOpen => _open;
  var _open = true;
}

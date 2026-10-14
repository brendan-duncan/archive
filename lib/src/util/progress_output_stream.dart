import 'dart:typed_data';

import 'byte_order.dart';
import 'input_decode_stream.dart';
import 'input_memory_stream.dart';
import 'input_stream.dart';
import 'output_stream.dart';
import 'report_progress.dart';

const _streamPieceSize = 1 << 20;

/// Passes every write to [output] and calls [onProgress] with the number of
/// bytes written through it, once per [interval] bytes and on flush and close.
/// If [onProgress] throws, it's Exception goes to the zone without stopping
/// the decoder/encoder.
///
/// A decoder rarely knows its output size in advance, so a fraction is read
/// off the input instead:
///
/// ```dart
/// final total = input.length;
/// final out = ProgressOutputStream(OutputFileStream(path),
///     (_) => onProgress(input.position / total));
/// const GZipDecoder().decodeStream(input, out);
/// ```
class ProgressOutputStream implements OutputStream {
  final OutputStream output;
  final void Function(int written) onProgress;
  final int interval;

  int _written = 0;
  int _reported = 0;

  ProgressOutputStream(this.output, this.onProgress, {this.interval = 0x10000});

  /// Bytes written through this stream so far
  int get written => _written;

  @override
  ByteOrder get byteOrder => output.byteOrder;

  @override
  set byteOrder(ByteOrder value) => output.byteOrder = value;

  @override
  int get length => output.length;

  @override
  bool get isOpen => output.isOpen;

  @override
  void open() => output.open();

  @override
  Future<void> close() async {
    try {
      _report();
    } finally {
      await output.close();
    }
  }

  @override
  void closeSync() {
    try {
      _report();
    } finally {
      output.closeSync();
    }
  }

  @override
  void clear() => output.clear();

  @override
  void flush() {
    output.flush();
    _report();
  }

  @override
  void writeByte(int value) {
    output.writeByte(value);
    _add(1);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    output.writeBytes(bytes, length: length);
    _add(length ?? bytes.length);
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    output.writeRange(bytes, start, end);
    _add(end - start);
  }

  @override
  void reserve(int total) => output.reserve(total);

  @override
  void writeStream(InputStream stream) {
    if (stream is InputDecodeStream) {
      final held = stream.position;
      final chunk = Uint8List(16 * 1024);
      try {
        while (!stream.isEOS) {
          final got = stream.readInto(chunk, 0, chunk.length);
          if (got <= 0) {
            return;
          }
          output.writeBytes(chunk, length: got);
          _add(got);
        }
      } finally {
        stream.setPosition(held);
      }
      return;
    }
    var left = stream.length;
    if (left <= _streamPieceSize) {
      output.writeStream(stream);
      _add(left);
      return;
    }
    final held = stream.position;
    output.reserve(output.length + left);
    try {
      if (stream is InputMemoryStream) {
        while (left > 0) {
          final count = left < _streamPieceSize ? left : _streamPieceSize;
          output.writeBytes(stream.readBytes(count).toUint8List());
          _add(count);
          left -= count;
        }
        return;
      }
      final chunk = Uint8List(_streamPieceSize);
      while (left > 0) {
        final got = stream.readInto(
            chunk, 0, left < _streamPieceSize ? left : _streamPieceSize);
        if (got <= 0) {
          return;
        }
        output.writeBytes(chunk, length: got);
        _add(got);
        left -= got;
      }
    } finally {
      stream.setPosition(held);
    }
  }

  @override
  void writeUint16(int value) {
    output.writeUint16(value);
    _add(2);
  }

  @override
  void writeUint32(int value) {
    output.writeUint32(value);
    _add(4);
  }

  @override
  void writeUint64(int value) {
    output.writeUint64(value);
    _add(8);
  }

  @override
  void writeBackReference(int distance, int count) {
    output.writeBackReference(distance, count);
    _add(count);
  }

  @override
  Uint8List subset(int start, [int? end]) => output.subset(start, end);

  @override
  Uint8List getBytes() => output.getBytes();

  void _add(int count) {
    _written += count;
    if (_written - _reported >= interval) {
      _reported = _written;
      reportProgress(onProgress, _written);
    }
  }

  void _report() {
    if (_written != _reported) {
      _reported = _written;
      reportProgress(onProgress, _written);
    }
  }
}

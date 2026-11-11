import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

/// A source that can be read in bounded chunks but refuses eager reads, and
/// counts the bytes read through it. Its [subset] hands back the inner stream,
/// as a checksumming wrapper does, so reads that go through a subset are not
/// counted.
class _NoEagerInput extends InputStream {
  _NoEagerInput(List<int> bytes)
      : _source = InputMemoryStream(bytes),
        super(byteOrder: ByteOrder.littleEndian);

  final InputMemoryStream _source;
  int read = 0;

  @override
  int get length => _source.length;
  @override
  int get position => _source.position;
  @override
  set position(int value) => _source.position = value;
  @override
  bool get isEOS => _source.isEOS;
  @override
  bool open() => _source.open();
  @override
  Future<void> close() => _source.close();
  @override
  void closeSync() => _source.closeSync();
  @override
  void reset() => _source.reset();
  @override
  void setPosition(int value) => _source.setPosition(value);
  @override
  void skip(int count) => _source.skip(count);
  @override
  void rewind([int count = 1]) => _source.rewind(count);
  @override
  InputStream subset({int? position, int? length, int? bufferSize}) => _source
      .subset(position: position, length: length, bufferSize: bufferSize);
  @override
  int readByte() => _source.readByte();
  @override
  int readInto(Uint8List into, int at, int count) {
    final got = _source.readInto(into, at, count);
    read += got;
    return got;
  }

  @override
  Uint8List toUint8List() => throw StateError('unexpected eager conversion');
}

class _CopyStreamDecoder extends ChunkDecoder {
  _CopyStreamDecoder(this.source);

  final InputStream source;
  bool _ran = false;

  @override
  bool decodeChunk(OutputStream output) {
    if (_ran) return false;
    _ran = true;
    output.writeStream(source);
    return false;
  }
}

class _ChunkedDecoder extends ChunkDecoder {
  _ChunkedDecoder(this.data);
  final Uint8List data;
  int position = 0;

  @override
  bool decodeChunk(OutputStream output) {
    final end = position + 1024 < data.length ? position + 1024 : data.length;
    output.writeBytes(Uint8List.sublistView(data, position, end));
    position = end;
    return position < data.length;
  }
}

Uint8List _fixture() =>
    Uint8List.fromList(List<int>.generate(512 * 1024, (i) => (i * 37) & 255));

void main() {
  for (final decodeWindow in [false, true]) {
    test('copying lazy source leaves its current byte readable: $decodeWindow',
        () {
      final data = _fixture();
      final source = InputDecodeStream(_ChunkedDecoder(data))..skip(17);
      if (decodeWindow) {
        final decoded = InputDecodeStream(_CopyStreamDecoder(source));
        expect(decoded.toUint8List(), data.sublist(17));
      } else {
        final out = OutputMemoryStream()..writeStream(source);
        expect(out.getBytes(), data.sublist(17));
      }
      expect(source.position, 17);
      expect(source.readByte(), data[17]);
    });
  }

  test('repeated memory stream appends retain amortized buffer growth', () {
    final output = OutputMemoryStream(size: 1);
    final source = InputMemoryStream([1]);
    var allocations = 0;
    var capacity = output.getBytes().buffer.lengthInBytes;
    for (var i = 0; i < 1000; i++) {
      output.writeStream(source);
      final next = output.getBytes().buffer.lengthInBytes;
      if (next != capacity) allocations++;
      capacity = next;
    }
    expect(output.getBytes(), List.filled(1000, 1));
    expect(allocations, lessThan(20));
  });

  test('OutputMemoryStream reads input through it in pieces, growing once', () {
    final data = _fixture();
    final input = _NoEagerInput(data)..skip(17);
    final output = OutputMemoryStream(size: 3);
    output.writeBytes([1, 2, 3]);
    output.writeStream(input);

    expect(output.getBytes(), [1, 2, 3, ...data.skip(17)]);
    expect(input.position, 17, reason: 'writeStream must preserve position');
    expect(input.read, data.length - 17);
    // Sized to the stream up front rather than doubled into
    expect(output.getBytes().buffer.lengthInBytes, data.length - 17 + 3);
  });

  test('OutputMemoryStream growth copies only written content', () {
    final output = OutputMemoryStream(size: 1024 * 1024);
    output.writeBytes([1, 2, 3]);
    // Force growth from a mostly unused 1 MiB reservation.
    output.writeBytes(Uint8List(1024 * 1024));
    expect(output.length, 1024 * 1024 + 3);
    expect(output.subset(0, 3), [1, 2, 3]);
    expect(output.subset(3).every((byte) => byte == 0), isTrue);
  });

  test('InputDecodeStream output copies large source in bounded chunks', () {
    final data = _fixture();
    final source = _NoEagerInput(data)..skip(31);
    final decoded = InputDecodeStream(_CopyStreamDecoder(source));
    final got = decoded.toUint8List();
    expect(got, data.sublist(31));
    expect(source.position, 31, reason: 'writeStream preserves source');
    expect(source.read, data.length - 31);
    decoded.closeSync();
  });

  test('OutputMemoryStream accepts lazy gzip output without draining source',
      () {
    final content = _fixture();
    final gz = GZipEncoder().encodeBytes(content);
    final source = GZipDecoder().decodeLazy(InputMemoryStream(gz));
    final out = OutputMemoryStream()..writeStream(source);
    expect(out.getBytes(), content);
  });
}

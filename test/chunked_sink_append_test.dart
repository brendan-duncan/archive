import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

class _RecordSink extends ChunkedSink {
  _RecordSink(Sink<List<int>> output, this.recordLength) : super(output);
  final int recordLength;
  int checksum = 0;
  int records = 0;

  @override
  void step() {
    while (available >= recordLength) {
      final bytes = view(recordLength);
      for (final byte in bytes) {
        checksum = (checksum * 33 + byte) & 0x7fffffff;
      }
      records++;
      skip(recordLength);
    }
  }

  @override
  void finish() {
    if (available != 0) {
      throw ArchiveException('Incomplete record');
    }
  }
}

class _Collector implements Sink<List<int>> {
  @override
  void add(List<int> data) {}
  @override
  void close() {}
}

void main() {
  test('incremental parsing remains exact through repeated in-place appends',
      () {
    final bytes = Uint8List.fromList(
      List<int>.generate(256 * 1024, (i) => (i * 71 + (i >> 4)) & 255),
    );

    _RecordSink parse(int chunkSize, {bool leadingByte = false}) {
      final sink = _RecordSink(_Collector(), 8);
      if (leadingByte) sink.addSlice(bytes, 0, 1, false);
      final reused = Uint8List(chunkSize + 4);
      for (var at = leadingByte ? 1 : 0; at < bytes.length; at += chunkSize) {
        final end =
            at + chunkSize < bytes.length ? at + chunkSize : bytes.length;
        reused.setRange(2, 2 + end - at, bytes, at);
        sink.addSlice(reused, 2, 2 + end - at, false);
        reused.fillRange(0, reused.length, 255);
      }
      sink.close();
      return sink;
    }

    final expected = parse(bytes.length);
    expect(expected.records, bytes.length ~/ 8);
    final compacted = parse(8, leadingByte: true);
    expect(compacted.records, expected.records);
    expect(compacted.checksum, expected.checksum);
    for (final chunk in [1, 2, 3, 5, 7, 8, 11, 64, 4096]) {
      final got = parse(chunk);
      expect(got.records, expected.records, reason: 'chunk $chunk');
      expect(got.checksum, expected.checksum, reason: 'chunk $chunk');
      expect(got.available, 0, reason: 'chunk $chunk');
    }
  });

  test('incomplete record still fails on close', () {
    final sink = _RecordSink(_Collector(), 8);
    sink.add([1, 2, 3]);
    expect(() => sink.close(), throwsA(isA<ArchiveException>()));
  });
}

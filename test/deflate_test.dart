import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  final buffer = Uint8List(0xfffff);
  for (var i = 0; i < buffer.length; ++i) {
    buffer[i] = i % 256;
  }

  test('NO_COMPRESSION', () {
    final deflated = Deflate(buffer, level: DeflateLevel.none).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_SPEED', () {
    final deflated = Deflate(buffer, level: DeflateLevel.bestSpeed).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_COMPRESSION', () {
    final deflated =
        Deflate(buffer, level: DeflateLevel.bestCompression).getBytes();

    final inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (var i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });
}

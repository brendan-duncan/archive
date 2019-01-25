import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  List<int> buffer = new List<int>(10000);
  for (int i = 0; i < buffer.length; ++i) {
    buffer[i] = i % 256;
  }

  test('encode/decode', () {
    List<int> compressed = new ZLibEncoder().encode(buffer);
    List<int> decompressed =
        new ZLibDecoder().decodeBytes(compressed, verify: true);
    expect(decompressed.length, equals(buffer.length));
    for (int i = 0; i < buffer.length; ++i) {
      expect(decompressed[i], equals(buffer[i]));
    }
  });
}

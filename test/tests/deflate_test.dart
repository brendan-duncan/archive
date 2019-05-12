import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  List<int> buffer = List<int>(0xfffff);
  for (int i = 0; i < buffer.length; ++i) {
    buffer[i] = i % 256;
  }

  test('NO_COMPRESSION', () {
    List<int> deflated =
        Deflate(buffer, level: Deflate.NO_COMPRESSION).getBytes();

    List<int> inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (int i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_SPEED', () {
    List<int> deflated =
        Deflate(buffer, level: Deflate.BEST_SPEED).getBytes();

    List<int> inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (int i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });

  test('BEST_COMPRESSION', () {
    List<int> deflated =
        Deflate(buffer, level: Deflate.BEST_COMPRESSION).getBytes();

    List<int> inflated = Inflate(deflated).getBytes();

    expect(inflated.length, equals(buffer.length));
    for (int i = 0; i < buffer.length; ++i) {
      expect(inflated[i], equals(buffer[i]));
    }
  });
}

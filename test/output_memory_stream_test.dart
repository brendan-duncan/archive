import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  group('OutputStreamMemory', () {
    test('empty', () async {
      final out = OutputMemoryStream();
      final bytes = out.getBytes();
      expect(bytes.length, equals(0));
    });

    test('writeByte', () async {
      final out = OutputMemoryStream();
      for (var i = 0; i < 10000; ++i) {
        out.writeByte(i % 256);
      }
      final bytes = out.getBytes();
      expect(bytes.length, equals(10000));
      for (var i = 0; i < 10000; ++i) {
        expect(bytes[i], equals(i % 256));
      }
    });

    test('writeUint16', () async {
      final out = OutputMemoryStream();

      const len = 0xffff;
      for (var i = 0; i < len; ++i) {
        out.writeUint16(i);
      }

      final bytes = out.getBytes();
      expect(bytes.length, equals(len * 2));

      final input = InputMemoryStream(bytes);
      for (var i = 0; i < len; ++i) {
        final x = input.readUint16();
        expect(x, equals(i));
      }
    });

    test('writeUint32', () async {
      final out = OutputMemoryStream();

      const len = 0xffff;
      for (var i = 0; i < len; ++i) {
        out.writeUint32(0xffff + i);
      }

      final bytes = out.getBytes();
      expect(bytes.length, equals(len * 4));

      final input = InputMemoryStream(bytes);
      for (var i = 0; i < len; ++i) {
        final x = input.readUint32();
        expect(x, equals(0xffff + i));
      }
    });
  });
}

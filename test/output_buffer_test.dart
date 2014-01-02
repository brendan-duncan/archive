part of archive_test;

void defineOutputBufferTests() {
  group('OutputBuffer', () {
    test('empty', () {
      OutputBuffer out = new OutputBuffer();
      List<int> bytes = out.getBytes();
      expect(bytes.length, equals(0));
    });

    test('writeByte', () {
      OutputBuffer out = new OutputBuffer();
      for (int i = 0; i < 10000; ++i) {
        out.writeByte(i % 256);
      }
      List<int> bytes = out.getBytes();
      expect(bytes.length, equals(10000));
      for (int i = 0; i < 10000; ++i) {
        expect(bytes[i], equals(i % 256));
      }
    });

    test('writeUint16', () {
      OutputBuffer out = new OutputBuffer();

      const int LEN = 0xffff;
      for (int i = 0; i < LEN; ++i) {
        out.writeUint16(i);
      }

      List<int> bytes = out.getBytes();
      expect(bytes.length, equals(LEN * 2));

      InputBuffer input = new InputBuffer(bytes);
      for (int i = 0; i < LEN; ++i) {
        int x = input.readUint16();
        expect(x, equals(i));
      }
    });

    test('writeUint32', () {
      OutputBuffer out = new OutputBuffer();

      const int LEN = 0xffff;
      for (int i = 0; i < LEN; ++i) {
        out.writeUint32(0xffff + i);
      }

      List<int> bytes = out.getBytes();
      expect(bytes.length, equals(LEN * 4));

      InputBuffer input = new InputBuffer(bytes);
      for (int i = 0; i < LEN; ++i) {
        int x = input.readUint32();
        expect(x, equals(0xffff + i));
      }
    });
  });
}

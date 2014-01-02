part of archive_test;

void defineDeflateTests() {
  group('deflate', () {
    List<int> buffer = new List<int>(10000);
    for (int i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('uncompressed', () {
      List<int> deflated = new Deflate(new InputBuffer(buffer),
          type: Deflate.UNCOMPRESSED).getBytes();
      List<int> inflated = new Inflate(new InputBuffer(deflated)).getBytes();

      expect(inflated.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(inflated[i], equals(buffer[i]));
      }
    });

    test('fixed_huffman', () {
      List<int> deflated = new Deflate(new InputBuffer(buffer),
          type: Deflate.FIXED_HUFFMAN).getBytes();
      List<int> inflated = new Inflate(new InputBuffer(deflated)).getBytes();

      expect(inflated.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(inflated[i], equals(buffer[i]));
      }
    });

    test('dynamic_huffman', () {
      List<int> deflated = new Deflate(new InputBuffer(buffer),
          type: Deflate.DYNAMIC_HUFFMAN).getBytes();
      List<int> inflated = new Inflate(new InputBuffer(deflated)).getBytes();

      expect(inflated.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(inflated[i], equals(buffer[i]));
      }
    });
  });
}

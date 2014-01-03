part of archive_test;

void defineGZipTests() {
  group('gzip', () {
    List<int> buffer = new List<int>(10000);
    for (int i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('encode/decode', () {
      List<int> compressed = new GZipEncoder().encode(buffer);
      List<int> decompressed = new GZipDecoder().decode(compressed,
                                                        verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('decode res/cat.jpg.gz', () {
      var b = new Io.File('res/cat.jpg');
      List<int> b_bytes = b.readAsBytesSync();

      var file = new Io.File('res/cat.jpg.gz');
      var bytes = file.readAsBytesSync();

      var z_bytes = new GZipDecoder().decode(bytes);
      compare_bytes(z_bytes, b_bytes);
    });

    test('decode res/a.txt.gz', () {
      List<int> a_bytes = a_txt.codeUnits;

      var file = new Io.File('res/a.txt.gz');
      var bytes = file.readAsBytesSync();

      var z_bytes = new GZipDecoder().decode(bytes);
      compare_bytes(z_bytes, a_bytes);
    });
  });
}

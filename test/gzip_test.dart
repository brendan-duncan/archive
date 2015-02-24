part of archive_test;

void defineGZipTests() {
  Io.File script = new Io.File(Io.Platform.script.toFilePath());
  String path = script.parent.path;

  group('gzip', () {
    List<int> buffer = new List<int>(10000);
    for (int i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('encode/decode', () {
      List<int> compressed = new GZipEncoder().encode(buffer);
      List<int> decompressed = new GZipDecoder().decodeBytes(compressed);
      expect(decompressed.length, equals(buffer.length));
      for (int i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('decode res/cat.jpg.gz', () {
      var b = new Io.File(path + '/res/cat.jpg');
      List<int> b_bytes = b.readAsBytesSync();

      var file = new Io.File(path + '/res/cat.jpg.gz');
      var bytes = file.readAsBytesSync();

      var z_bytes = new GZipDecoder().decodeBytes(bytes);
      compare_bytes(z_bytes, b_bytes);
    });

    test('decode res/a.txt.gz', () {
      List<int> a_bytes = a_txt.codeUnits;

      var file = new Io.File(path + '/res/a.txt.gz');
      var bytes = file.readAsBytesSync();

      var z_bytes = new GZipDecoder().decodeBytes(bytes);
      compare_bytes(z_bytes, a_bytes);
    });

    test('encode res/cat.jpg', () {
      var b = new Io.File(path + '/res/cat.jpg');
      List<int> b_bytes = b.readAsBytesSync();

      List<int> compressed = new GZipEncoder().encode(b_bytes);
      Io.File f = new Io.File(path + '/out/cat.jpg.gz');
      f.createSync(recursive: true);
      f.writeAsBytesSync(compressed);
    });
  });
}

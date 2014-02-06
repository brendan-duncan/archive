part of archive_test;


void defineBzip2Tests() {
  group('bzip2', () {
    List<int> orig;
    List<int> decompressed;

    test('decode', () {
      List<int> orig =
          new Io.File('res/bzip2/test.bz2').readAsBytesSync();

      decompressed = new BZip2Decoder().decodeBytes(orig);
    });

    test('encode', () {
      /*List<int> compressed = new BZip2Encoder().encode(decompressed);
      List<int> d2 = new BZip2Decoder().decodeBytes(compressed);
      expect(d2.length, equals(decompressed.length));
      for (int i = 0, len = d2.length; i < len; ++i) {
        expect(d2[i], equals(decompressed[i]));
      }*/
    });
  });
}

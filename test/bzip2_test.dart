part of archive_test;


void defineBzip2Tests() {
  group('bzip2', () {
    test('decode', () {
      List<int> compressed =
          new Io.File('res/bzip2/test.bz2').readAsBytesSync();

      List<int> decompressed = new BZip2Decoder().decodeBytes(compressed);
    });
  });
}

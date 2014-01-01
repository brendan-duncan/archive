
part of archive_test;

void defineCrc32Tests() {
  group('crc32', () {
    test('empty', () {
      int crcVal = getCrc32([]);
      expect(crcVal, 0);
    });
    test('1 byte', () {
      int crcVal = getCrc32([1]);
      expect(crcVal, 2768625435);
    });
    test('10 bytes', () {
      int crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0]);
      expect(crcVal, 3321216613);
    });
    test('100000 bytes', () {
      int crcVal = getCrc32([]);
      for (int i = 0; i < 10000; i++) {
        crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0], crcVal);
      }
      // TODO: this test fails - perhaps the int is overflowing 32 bits?
      expect(crcVal, 986086443);
    });
  });
}


part of archive_test;

void defineAdlerTests() {
  group('adler32', () {
    test('empty', () {
      int adlerVal = getAdler32([]);
      expect(adlerVal, 1);
    });
    test('1 byte', () {
      int adlerVal = getAdler32([1]);
      expect(adlerVal, 0x20002);
    });
    test('10 bytes', () {
      int adlerVal = getAdler32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0]);
      expect(adlerVal, 0xDC002E);
    });
    test('100000 bytes', () {
      int adlerVal = 1;
      for (int i = 0; i < 10000; i++) {
        adlerVal = getAdler32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0], adlerVal);
      }
      expect(adlerVal, 0x96C8DE2B);
    });
  });
}

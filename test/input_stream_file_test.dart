import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  final testData = Uint8List(120);
  for (var i = 0; i < testData.length; ++i) {
    testData[i] = i;
  }
  const testPath = '$testOutputPath/test_123.bin';
  File(testPath)
  ..createSync(recursive:true)
  ..writeAsBytesSync(testData);
  
  group('InputStreamFile', () {
    test('length', () async {
      final fs = InputStreamFile(testPath);
      await fs.open();
      expect(fs.length, testData.length);
    });

    test('readBytes', () async {
      final input = InputStreamFile(testPath);
      await input.open();
      expect(input.length, equals(120));
      var same = true;
      var ai = 0;
      while (!input.isEOS) {
        final bs = await input.readBytes(50);
        final bytes = await bs.toUint8List();
        for (var i = 0; i < bytes.length; ++i) {
          same = bytes[i] == ai + i;
          if (!same) {
            expect(same, equals(true));
            return;
          }
        }
        ai += bytes.length;
      }
    });

    test('position', () async {
      final fs = InputStreamFile(testPath, bufferSize: 2);
      await fs.open();
      await fs.setPosition(50);
      final bs = await fs.readBytes(50);
      final b = await bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('skip', () async {
      final fs = InputStreamFile(testPath, bufferSize: 2);
      await fs.open();
      await fs.skip(50);
      final bs = await fs.readBytes(50);
      final b = await bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('rewind', () async {
      final fs = InputStreamFile(testPath, bufferSize: 2);
      await fs.open();
      await fs.skip(50);
      await fs.rewind(10);
      final bs = await fs.readBytes(50);
      final b = await bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[40 + i]);
      }
    });

    test('peakBytes', () async {
      final fs = InputStreamFile(testPath, bufferSize: 2);
      await fs.open();
      final bs = await fs.peekBytes(10);
      final b = await bs.toUint8List();
      expect(fs.position, 0);
      expect(b.length, 10);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[i]);
      }
    });

    test("clone", () async {
      final input = InputStreamFile(testPath);
      await input.open();
      final input2 = InputStreamFile.from(input, position: 6, length: 5);
      final bs = await input2.readBytes(5);
      final b = await bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });
}

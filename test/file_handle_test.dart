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
  final testPath = '$testOutputPath/test_123.bin';
  File(testPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(testData);

  group('FileHandle', () {
    test('open', () async {
      final fh = FileHandle(testPath);
      expect(fh.isOpen, true);
      await fh.close();
      expect(fh.isOpen, false);
    });

    test('length', () async {
      final fh = FileHandle(testPath);
      expect(fh.length, testData.length);
    });

    test('position', () async {
      final fh = FileHandle(testPath);
      fh.position = 10;
      expect(fh.position, equals(10));
      fh.position = fh.length - 10;
      expect(fh.position, equals(110));
    });

    test('readInto', () async {
      final fh = FileHandle(testPath);
      final bytes = Uint8List(10);
      fh.readInto(bytes);
      for (var i = 0; i < 10; ++i) {
        expect(bytes[i], equals(i));
      }
    });
  });
}

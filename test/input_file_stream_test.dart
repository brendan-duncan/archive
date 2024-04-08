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
      final fs = InputFileStream(testPath)..open();
      expect(fs.length, testData.length);
    });

    test('readBytes', () async {
      final input = InputFileStream(testPath)..open();
      expect(input.length, equals(120));
      var same = true;
      var ai = 0;
      while (!input.isEOS) {
        final bs = input.readBytes(50);
        final bytes = bs.toUint8List();
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
      final fs = InputFileStream(testPath, bufferSize: 2)
      ..open()
      ..setPosition(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('skip', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
      ..open()
      ..skip(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('rewind', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
      ..open()
      ..skip(50)
      ..rewind(10);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[40 + i]);
      }
    });

    test('peakBytes', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
      ..open();
      final bs = fs.peekBytes(10);
      final b = bs.toUint8List();
      expect(fs.position, 0);
      expect(b.length, 10);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[i]);
      }
    });

    test("clone", () async {
      final input = InputFileStream(testPath)
      ..open();
      final input2 = InputFileStream.fromFileStream(input, position: 6, length: 5);
      final bs = input2.readBytes(5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });
}

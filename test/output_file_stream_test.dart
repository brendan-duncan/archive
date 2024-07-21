import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('OutputFileStream', () {
    test('InputFileStream/OutputFileStream', () async {
      final input = InputFileStream('test/_data/folder.zip')..open();
      final output = OutputFileStream('$testOutputPath/folder.zip')..open();

      while (!input.isEOS) {
        final bytes = input.readBytes(50);
        output.writeStream(bytes);
      }

      await input.close();
      await output.close();

      final aBytes = File('test/_data/folder.zip').readAsBytesSync();
      final bBytes = File('$testOutputPath/folder.zip').readAsBytesSync();

      expect(aBytes.length, equals(bBytes.length));
      for (var i = 0; i < aBytes.length; ++i) {
        expect(aBytes[i], equals(bBytes[i]));
      }
    });

    test('InputMemoryStream/OutputFileStream', () async {
      final bytes = List<int>.generate(256, (index) => index);
      final input = InputMemoryStream.fromList(bytes)..open();
      final output = OutputFileStream('$testOutputPath/test.bin')..open();

      while (!input.isEOS) {
        final bytes = input.readBytes(50);
        output.writeStream(bytes);
      }

      await input.close();
      await output.close();

      final aBytes = File('$testOutputPath/test.bin').readAsBytesSync();

      expect(aBytes.length, equals(bytes.length));
      for (var i = 0; i < aBytes.length; ++i) {
        expect(aBytes[i], equals(bytes[i]));
      }
    });

    test('InputFileStream/OutputMemoryStream', () async {
      final input = InputFileStream('test/_data/folder.zip')..open();
      final output = OutputMemoryStream()..open();

      while (!input.isEOS) {
        final bytes = input.readBytes(50);
        output.writeStream(bytes);
      }

      await input.close();

      final aBytes = File('test/_data/folder.zip').readAsBytesSync();
      final bBytes = output.getBytes();

      expect(aBytes.length, equals(bBytes.length));
      for (var i = 0; i < aBytes.length; ++i) {
        expect(aBytes[i], equals(bBytes[i]));
      }
    });
  });
}

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('OutputStreamFile', () {
    test('InputStreamFile/OutputStreamFile', () async {
      final input = InputStreamFile('test/_data/folder.zip');
      await input.open();
      final output = OutputStreamFile('$testOutputPath/folder.zip');
      await output.open();

      while (!input.isEOS) {
        final bytes = await input.readBytes(50);
        await output.writeStream(bytes);
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

    test('InputStreamMemory/OutputStreamFile', () async {
      final bytes = List<int>.generate(256, (index) => index);
      final input = InputStreamMemory.fromList(bytes);
      await input.open();
      final output = OutputStreamFile('$testOutputPath/test.bin');
      await output.open();

      while (!input.isEOS) {
        final bytes = await input.readBytes(50);
        await output.writeStream(bytes);
      }

      await input.close();
      await output.close();

      final aBytes = File('$testOutputPath/test.bin').readAsBytesSync();

      expect(aBytes.length, equals(bytes.length));
      for (var i = 0; i < aBytes.length; ++i) {
        expect(aBytes[i], equals(bytes[i]));
      }
    });

    test('InputStreamFile/OutputStreamMemory', () async {
      final input = InputStreamFile('test/_data/folder.zip');
      await input.open();
      final output = OutputStreamMemory();
      await output.open();

      while (!input.isEOS) {
        final bytes = await input.readBytes(50);
        await output.writeStream(bytes);
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

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('OutputFileStream', () {
    test('InputFileStream/OutputFileStream', testOn: 'vm', () async {
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

    test('InputMemoryStream/OutputFileStream', testOn: 'vm', () async {
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

    test('InputFileStream/OutputMemoryStream', testOn: 'vm', () async {
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

  // A RAM file once read start and end as file positions rather than indices
  // into the buffer, which only a range starting past zero shows
  group('OutputFileStream over RamFileHandle', () {
    Uint8List readAll(RamFileHandle handle) {
      final out = Uint8List(handle.length);
      handle.position = 0;
      handle.readInto(out, out.length);
      return out;
    }

    test('writeRange larger than buffer writes exact range', () {
      final handle = RamFileHandle.asWritableRamBuffer();
      final out = OutputFileStream.toRamFile(handle, bufferSize: 16);
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      out.writeRange(bytes, 10, 100);
      out.flush();
      expect(readAll(handle), Uint8List.sublistView(bytes, 10));
    });

    test('writeBytes of view writes only bytes of view', () {
      final handle = RamFileHandle.asWritableRamBuffer();
      final out = OutputFileStream.toRamFile(handle, bufferSize: 16);
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      out
        ..writeBytes(Uint8List.sublistView(bytes, 10, 90))
        ..writeBytes(Uint8List.sublistView(bytes, 3, 7))
        ..writeBytes(Uint8List.sublistView(bytes, 20, 60), length: 30);
      out.flush();
      expect(readAll(handle), [
        ...bytes.sublist(10, 90),
        ...bytes.sublist(3, 7),
        ...bytes.sublist(20, 50),
      ]);
    });

    test('zstd decodeStream into it writes exact bytes', () {
      // Three megabytes, so the window flushes in ranges that start past zero
      var seed = 1;
      final data = Uint8List.fromList(List.generate(3 << 20, (_) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return (seed >> 16) % 7 + 97;
      }));
      final packed = ZstdEncoder(level: 3).encodeBytes(data);
      final handle = RamFileHandle.asWritableRamBuffer();
      final out = OutputFileStream.toRamFile(handle);
      expect(
          ZstdDecoder().decodeStream(InputMemoryStream(packed), out), isTrue);
      out.flush();
      expect(readAll(handle), data);
    });
  });
}

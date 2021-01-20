import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('InputFileStream', () {
    // Test fundamental assumption setPositionSync does what we expect.
    final fp = File(p.join(testDirPath, 'res/cat.jpg')).openSync();
    fp.setPositionSync(9);
    var b1 = fp.readByteSync();
    var b2 = fp.readByteSync();
    fp.setPositionSync(9);
    var c1 = fp.readByteSync();
    var c2 = fp.readByteSync();
    expect(b1, equals(c1));
    expect(b2, equals(c2));

    // Test rewind across buffer boundary.
    var input =
        InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);

    for (var i = 0; i < 9; ++i) {
      input.readByte();
    }
    b1 = input.readByte();
    b2 = input.readByte();
    input.rewind(2);
    c1 = input.readByte();
    c2 = input.readByte();
    expect(b1, equals(c1));
    expect(b2, equals(c2));

    // Test if peekBytes works across a buffer boundary.
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 9; ++i) {
      input.readByte();
    }
    b1 = input.readByte();
    b2 = input.readByte();

    input.close();
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 9; ++i) {
      input.readByte();
    }

    final b = input.peekBytes(2);
    expect(b.length, equals(2));
    expect(b[0], equals(b1));
    expect(b[1], equals(b2));

    final c = input.readBytes(2);
    expect(b[0], equals(c[0]));
    expect(b[1], equals(c[1]));

    input.close();

    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    final input2 =
        InputStream(File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync());

    var same = true;
    while (!input.isEOS && same) {
      same = input.readByte() == input2.readByte();
    }
    expect(same, equals(true));
    expect(input.isEOS, equals(input2.isEOS));

    // Test skip across buffer boundary
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 11; ++i) {
      input.readByte();
    }
    b1 = input.readByte();
    input.close();
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 9; ++i) {
      input.readByte();
    }
    input.skip(2);
    c1 = input.readByte();
    expect(b1, equals(c1));
    input.close();

    // Test skip to end of buffer
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 10; ++i) {
      input.readByte();
    }
    b1 = input.readByte();
    input.close();
    input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'), bufferSize: 10);
    for (var i = 0; i < 9; ++i) {
      input.readByte();
    }
    input.skip(1);
    c1 = input.readByte();
    expect(b1, equals(c1));
    input.close();
  });

  test('InputFileStream/OutputFileStream', () {
    var input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'));
    var output = OutputFileStream(p.join(testDirPath, 'out/cat2.jpg'));
    while (!input.isEOS) {
      var bytes = input.readBytes(50);
      output.writeInputStream(bytes);
    }
    input.close();
    output.close();

    var a_bytes = File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();
    var b_bytes = File(p.join(testDirPath, 'out/cat2.jpg')).readAsBytesSync();

    expect(a_bytes.length, equals(b_bytes.length));
    var same = true;
    for (var i = 0; same && i < a_bytes.length; ++i) {
      same = a_bytes[i] == b_bytes[i];
    }
    expect(same, equals(true));
  });

  test('empty file', () {
    var encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/testEmpty.zip');
    encoder.addFile(File('$testDirPath/res/emptyfile.txt'));
    encoder.close();

    var zipDecoder = ZipDecoder();
    var f = File('${testDirPath}/out/testEmpty.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(1));
  });

  test('stream tar decode', () {
    // Decode a tar from disk to memory
    var stream = InputFileStream(p.join(testDirPath, 'res/test2.tar'));
    var tarArchive = TarDecoder();
    tarArchive.decodeBuffer(stream);

    for (final file in tarArchive.files) {
      if (!file.isFile) {
        continue;
      }
      var filename = file.filename;
      try {
        var f = File('${testDirPath}/out/${filename}');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(file.content as List<int>);
      } catch (e) {
        print(e);
      }
    }

    expect(tarArchive.files.length, equals(4));
  });

  test('stream tar encode', () {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.open('$testDirPath/out/test3.tar');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    encoder.close();
  });

  test('stream gzip encode', () {
    final input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'));
    final output = OutputFileStream(p.join(testDirPath, 'out/cat.jpg.gz'));

    final encoder = GZipEncoder();
    encoder.encode(input, output: output);
  });

  test('stream gzip decode', () {
    var input = InputFileStream(p.join(testDirPath, 'out/cat.jpg.gz'));
    var output = OutputFileStream(p.join(testDirPath, 'out/cat.jpg'));

    GZipDecoder().decodeStream(input, output);
  });

  test('stream tgz encode', () {
    // Encode a directory from disk to disk, no memory
    var encoder = TarFileEncoder();
    encoder.create('$testDirPath/out/example2.tar');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    encoder.close();

    var input = InputFileStream(p.join(testDirPath, 'out/example2.tar'));
    var output = OutputFileStream(p.join(testDirPath, 'out/example2.tgz'));
    GZipEncoder().encode(input, output: output);
    input.close();
    File(input.path).deleteSync();
  });

  test('stream zip encode', () {
    var encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/example2.zip');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    encoder.addFile(File('$testDirPath/res/cat.jpg'));
    encoder.addFile(File('$testDirPath/res/tarurls.txt'));
    encoder.close();

    var zipDecoder = ZipDecoder();
    var f = File('${testDirPath}/out/example2.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(4));
  });

  test('create_archive_from_directory', () {
    var dir = Directory('$testDirPath/res/test2');
    var archive = createArchiveFromDirectory(dir);
    expect(archive.length, equals(2));
    var encoder = ZipEncoder();

    var bytes = encoder.encode(archive)!;

    var zipDecoder = ZipDecoder();
    var archive2 = zipDecoder.decodeBytes(bytes, verify: true);
    expect(archive2.length, equals(2));
  });
}

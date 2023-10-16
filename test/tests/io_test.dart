// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_utils.dart';

Uint8List? fileData;

void writeFile(String path, int size) {
  if (fileData == null) {
    const oneMeg = 1024 * 1024;
    fileData = Uint8List(oneMeg);
    for (var i = 0, l = fileData!.length; i < l; ++i) {
      fileData![i] = i % 256;
    }
  }
  final fp = File(path);
  fp.createSync(recursive: true);
  fp.openSync(mode: FileMode.writeOnly);
  while (size > fileData!.length) {
    fp.writeAsBytesSync(fileData!);
    size -= fileData!.length;
  }
  if (size > 0) {
    final remaining = Uint8List.view(fileData!.buffer, 0, size);
    fp.writeAsBytesSync(remaining);
  }
}

void generateDataDirectory(String path,
    {required int fileSize, required int numFiles}) {
  for (var i = 0; i < numFiles; ++i) {
    writeFile('$path/$i.bin', fileSize);
  }
}

void main() {
  final testPath = p.join(testDirPath, 'out/test_123.bin');
  final testData = Uint8List(120);
  for (var i = 0; i < testData.length; ++i) {
    testData[i] = i;
  }

  // Add an empty directory to test2
  Directory('$testDirPath/res/test2/empty').createSync(recursive: true);

  final testFile = File(testPath);
  testFile.createSync(recursive: true);
  testFile.openSync(mode: FileMode.write);
  testFile.writeAsBytesSync(testData);

  test('FileBuffer', () async {
    FileBuffer fb = FileBuffer(testPath, bufferSize: 5);
    expect(fb.length, equals(testData.length));
    var indices = [5, 110, 0, 64];
    for (final i in indices) {
      var b = fb.readUint8(i, fb.length);
      expect(b, equals(testData[i]));
    }

    final bytes = fb.readBytes(5, 10, fb.length);
    expect(bytes, equals(testData.sublist(5, 5 + 10)));

    final bytes2 = fb.readBytes(115, 10, fb.length);
    expect(bytes2.length, equals(5));
    expect(bytes2, equals(testData.sublist(115, 115 + 5)));

    final u16 = fb.readUint16(8, fb.length);
    expect(u16, equals(2312));

    final u24 = fb.readUint24(50, fb.length);
    expect(u24, equals(3420978));

    final u32 = fb.readUint32(15, fb.length);
    expect(u32, equals(303108111));

    // make sure re-reading the same position is consistent
    final u32_2 = fb.readUint32(15, fb.length);
    expect(u32_2, equals(303108111));

    final u64 = fb.readUint64(0, fb.length);
    expect(u64, equals(0x0706050403020100));
  });

  group('InputFileStream', () {
    test('length', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      expect(fs.length, testData.length);
    });

    test('readByte', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      for (var i = 0; i < testData.length; ++i) {
        expect(fs.readByte(), testData[i]);
      }
    });

    test('readBytes', () {
      final input = InputFileStream(testPath);
      expect(input.length, equals(120));
      var ai = 0;
      while (!input.isEOS) {
        final bs = input.readBytes(40);
        expect(bs.length, 40);
        final bytes = bs.toUint8List();
        expect(bytes.length, 40);
        for (var i = 0; i < bytes.length; ++i) {
          expect(bytes[i], equals(ai + i));
        }
        ai += bytes.length;
      }
    });

    test('position', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      fs.position = 50;
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('skip', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      fs.skip(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('rewind', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      fs.skip(50);
      fs.rewind(10);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[40 + i]);
      }
    });

    test('rewind 2', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      fs.rewind(50);
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], fs.readByte());
      }
    });

    test('peakBytes', () {
      final fs = InputFileStream(testPath, bufferSize: 2);
      final bs = fs.peekBytes(10);
      final b = bs.toUint8List();
      expect(fs.position, 0);
      expect(b.length, 10);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[i]);
      }
    });

    test("clone", () {
      final input = InputFileStream(testPath);
      final input2 = InputFileStream.clone(input, position: 6, length: 5);
      final bs = input2.readBytes(5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });

  test('InputFileStream/OutputFileStream', () {
    var input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'));
    var output = OutputFileStream(p.join(testDirPath, 'out/cat2.jpg'));
    var offset = 0;
    var inputLength = input.length;
    while (!input.isEOS) {
      final bytes = input.readBytes(50);
      if (offset + 50 > inputLength) {
        final remaining = inputLength - offset;
        expect(bytes.length, equals(remaining));
      }
      offset += bytes.length;
      output.writeInputStream(bytes);
    }
    input.close();
    output.close();

    final aBytes = File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();
    final bBytes = File(p.join(testDirPath, 'out/cat2.jpg')).readAsBytesSync();

    expect(aBytes.length, equals(bBytes.length));
    var same = true;
    for (var i = 0; same && i < aBytes.length; ++i) {
      same = aBytes[i] == bBytes[i];
    }
    expect(same, equals(true));
  });

  test('empty file', () {
    final encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/testEmpty.zip');
    encoder.addFile(File('$testDirPath/res/emptyfile.txt'));
    encoder.close();

    final zipDecoder = ZipDecoder();
    final f = File('$testDirPath/out/testEmpty.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(1));
  });

  test('stream tar decode', () {
    // Decode a tar from disk to memory
    final stream = InputFileStream(p.join(testDirPath, 'res/test2.tar'));
    final tarArchive = TarDecoder();
    tarArchive.decodeBuffer(stream);

    for (final file in tarArchive.files) {
      if (!file.isFile) {
        continue;
      }
      final filename = file.filename;
      try {
        final f = File('$testDirPath/out/$filename');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(file.content as List<int>);
      } catch (e) {
        print(e);
      }
    }

    expect(tarArchive.files.length, equals(4));
  });

  test('stream zip decode', () {
    // Decode a tar from disk to memory
    final stream = InputFileStream(p.join(testDirPath, 'res/test.zip'));
    final zip = ZipDecoder().decodeBuffer(stream);

    expect(zip.files.length, equals(2));
    expect(zip.files[0].name, equals("a.txt"));
    expect(zip.files[1].name, equals("cat.jpg"));
    expect(zip.files[1].content.length, equals(51662));
  });

  test('stream tar encode', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.open('$testDirPath/out/test3.tar');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    await encoder.close();

    final tarDecoder = TarDecoder();
    final f = File('$testDirPath/out/test3.tar');
    final archive = tarDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(4));
  });

  test('stream gzip encode', () {
    final input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'));
    final output = OutputFileStream(p.join(testDirPath, 'out/cat.jpg.gz'));

    final encoder = GZipEncoder();
    encoder.encode(input, output: output);
    output.close();
  });

  test('stream gzip decode', () {
    final input = InputFileStream(p.join(testDirPath, 'out/cat.jpg.gz'));
    final output = OutputFileStream(p.join(testDirPath, 'out/cat.jpg'));

    GZipDecoder().decodeStream(input, output);
    output.close();
  });

  test('TarFileEncoder -> GZipEncoder', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.create('$testDirPath/out/example2.tar');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    await encoder.close();

    final input = InputFileStream(p.join(testDirPath, 'out/example2.tar'));
    final output = OutputFileStream(p.join(testDirPath, 'out/example2.tgz'));
    GZipEncoder().encode(input, output: output);
    input.close();
    output.close();
  });

  test('TarFileEncoder tgz', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.tarDirectory(Directory('$testDirPath/res/test2'),
        filename: '$testDirPath/out/example2.tgz', compression: 1);
    encoder.close();
  });

  test('stream zip encode', () {
    final encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/example2.zip');
    encoder.addDirectory(Directory('$testDirPath/res/test2'));
    encoder.addFile(File('$testDirPath/res/cat.jpg'));
    encoder.addFile(File('$testDirPath/res/tarurls.txt'));
    encoder.close();

    final zipDecoder = ZipDecoder();
    final f = File('$testDirPath/out/example2.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(6));
  });

  test('decode_empty_directory', () {
    final zip = ZipDecoder();
    final archive =
        zip.decodeBytes(File('$testDirPath/res/test2.zip').readAsBytesSync());
    expect(archive.length, 4);
  });

  test('create_archive_from_directory', () {
    final dir = Directory('$testDirPath/res/test2');
    final archive = createArchiveFromDirectory(dir);
    expect(archive.length, equals(4));
    final encoder = ZipEncoder();

    final bytes = encoder.encode(archive)!;
    File('$testDirPath/out/test2_.zip')
      ..openSync(mode: FileMode.write)
      ..writeAsBytesSync(bytes);

    final zipDecoder = ZipDecoder();
    final archive2 = zipDecoder.decodeBytes(bytes, verify: true);
    expect(archive2.length, equals(4));
  });

  test('file close', () {
    final testPath = p.join(testDirPath, 'out/test2.bin');
    final testData = Uint8List(120);
    for (var i = 0; i < testData.length; ++i) {
      testData[i] = i;
    }
    final testFile = File(testPath);
    testFile.createSync(recursive: true);
    final fp = testFile.openSync(mode: FileMode.write);
    fp.writeFromSync(testData);
    fp.closeSync();

    final input = InputFileStream(testPath);
    final bs = input.readBytes(50);
    expect(bs.length, 50);
    input.close();

    testFile.delete();
  });

  test('extractFileToDisk tar', () async {
    final inPath = '$testDirPath/res/test2.tar';
    final outPath = '$testDirPath/out/extractFileToDisk_tar';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk tar.gz', () async {
    final inPath = '$testDirPath/res/test2.tar.gz';
    final outPath = '$testDirPath/out/extractFileToDisk_tgz';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk tar.tbz', () async {
    final inPath = '$testDirPath/res/test2.tar.bz2';
    final outPath = '$testDirPath/out/extractFileToDisk_tbz';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk zip', () async {
    final inPath = '$testDirPath/res/test.zip';
    final outPath = '$testDirPath/out/extractFileToDisk_zip';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 2);
  });

  test('extractFileToDisk zip bzip2', () async {
    final inPath = '$testDirPath/res/zip/zip_bzip2.zip';
    final outPath = '$testDirPath/out/extractFileToDisk_zip_bzip2';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 2);
  });

  test('extractArchiveToDisk symlink', () async {
    final f1 = ArchiveFile('test', 3, 'foo'.codeUnits);
    final f2 = ArchiveFile('link', 0, null);
    f2.isSymbolicLink = true;
    f2.nameOfLinkedFile = './../test.tar';
    final a = Archive();
    a.addFile(f1);
    a.addFile(f2);
    extractArchiveToDisk(a, '$testDirPath/out/extractArchiveToDisk_symlink');
  });

  test('zip directory', () async {
    final tmpPath = '$testDirPath/out/test_zip_dir';

    generateDataDirectory(tmpPath, fileSize: 1024, numFiles: 5);

    final inPath = '$testDirPath/out/test_zip_dir_2.zip';
    final outPath = '$testDirPath/out/test_zip_dir_2';

    var count = 0;
    final encoder = ZipFileEncoder();
    await encoder.zipDirectoryAsync(Directory(tmpPath),
        level: 0, filename: inPath, onProgress: (double x) {
      count++;
    });

    expect(count, equals(5));

    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final srcFiles = Directory(tmpPath).listSync(recursive: true);
    final dstFiles =
        Directory('$testDirPath/out/test_zip_dir_2').listSync(recursive: true);
    expect(dstFiles.length, equals(srcFiles.length));
    //encoder.close();
  });
}

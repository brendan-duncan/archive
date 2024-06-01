// ignore_for_file: avoid_print

import 'dart:async';
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

Future<InputFileStream> _buildFileIFS(String path, [int? bufferSize]) async {
  if (bufferSize == null) {
    return InputFileStream(path);
  } else {
    return InputFileStream(path, bufferSize: bufferSize);
  }
}

Future<InputFileStream> _buildRamIfs(String path, [int? bufferSize]) async {
  final File file = File(path);
  final int fileLength = file.lengthSync();
  final rawFileStream = file.openRead();
  final fileStream = rawFileStream.transform(
    StreamTransformer<List<int>, Uint8List>.fromHandlers(
      handleData: (List<int> data, EventSink<Uint8List> sink) {
        final uint8List = Uint8List.fromList(data);
        sink.add(uint8List);
      },
    ),
  );
  final RamFileHandle fileHandle =
      await RamFileHandle.fromStream(fileStream, fileLength);
  if (bufferSize == null) {
    return InputFileStream.withFileBuffer(FileBuffer(fileHandle));
  } else {
    return InputFileStream.withFileBuffer(
        FileBuffer(fileHandle, bufferSize: bufferSize));
  }
}

Future<OutputFileStream> _buildFileOFS(String path) async {
  return OutputFileStream(path);
}

Future<OutputFileStream> _buildRamOfs(String path) async {
  return OutputFileStream.toRamFile(RamFileHandle.asWritableRamBuffer());
}

void _testInputFileStream(
  String description,
  dynamic Function(
    Future<InputFileStream> Function(String, [int?]) ifsConstructor,
  ) testFunction,
) {
  test('$description (file)', () => testFunction(_buildFileIFS));
  test('$description (ram)', () => testFunction(_buildRamIfs));
}

void _testInputOutputFileStream(
  String description,
  dynamic Function(
    Future<InputFileStream> Function(String, [int?]) ifsConstructor,
    Future<OutputFileStream> Function(String) ofsConstructor,
  ) testFunction,
) {
  test('$description (file > file)',
      () => testFunction(_buildFileIFS, _buildFileOFS));
  test('$description (file > ram)',
      () => testFunction(_buildFileIFS, _buildRamOfs));
  test('$description (ram > file)',
      () => testFunction(_buildRamIfs, _buildFileOFS));
  test('$description (ram > ram)',
      () => testFunction(_buildRamIfs, _buildRamOfs));
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

  test('FileHandle', () async {});

  test('FileBuffer', () async {
    FileBuffer fb = FileBuffer(FileHandle(testPath), bufferSize: 5);
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
    _testInputFileStream('length', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      expect(fs.length, testData.length);
    });

    _testInputFileStream('readByte', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      for (var i = 0; i < testData.length; ++i) {
        expect(fs.readByte(), testData[i],
            reason: 'Byte at index $i was incorrect');
      }
    });

    _testInputFileStream('readBytes', (ifsConstructor) async {
      final input = await ifsConstructor(testPath);
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

    _testInputFileStream('position', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      fs.position = 50;
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    _testInputFileStream('skip', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      fs.skip(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    _testInputFileStream('rewind', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      fs.skip(50);
      fs.rewind(10);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[40 + i]);
      }
    });

    _testInputFileStream('rewind 2', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      fs.rewind(50);
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], fs.readByte());
      }
    });

    _testInputFileStream('peakBytes', (ifsConstructor) async {
      final fs = await ifsConstructor(testPath, 2);
      final bs = fs.peekBytes(10);
      final b = bs.toUint8List();
      expect(fs.position, 0);
      expect(b.length, 10);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[i]);
      }
    });

    _testInputFileStream("clone", (ifsConstructor) async {
      final input = await ifsConstructor(testPath);
      final input2 = InputFileStream.clone(input, position: 6, length: 5);
      final bs = input2.readBytes(5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });

  test('InputFileStream/OutputFileStream (files)', () {
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
    input.closeSync();
    output.closeSync();

    final aBytes = File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();
    final bBytes = File(p.join(testDirPath, 'out/cat2.jpg')).readAsBytesSync();

    expect(aBytes.length, equals(bBytes.length));
    var same = true;
    for (var i = 0; same && i < aBytes.length; ++i) {
      same = aBytes[i] == bBytes[i];
    }
    expect(same, equals(true));
  });

  test('InputFileStream/OutputFileStream (ram)', () {
    var input = InputFileStream(p.join(testDirPath, 'res/cat.jpg'));
    final RamFileHandle rfh = RamFileHandle.asWritableRamBuffer();
    var output = OutputFileStream.toRamFile(rfh);
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
    input.closeSync();
    output.closeSync();

    final aBytes = File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();
    final bBytes = Uint8List(rfh.length);
    rfh.readInto(bBytes);

    compareBytes(bBytes, aBytes);
    output.closeSync();
  });

  test('Zip in RAM and then unzip from RAM', () {
    final testFiles = [
      'a.txt.gz',
      'cat.jpg',
      'cat.jpg.gz',
      'emptyfile.txt',
      'example.tar',
      'tarurls.txt',
      'test_100k_files.zip',
      'test2.tar',
      'test2.tar.bz2',
      'test2.tar.gz',
      'test2.zip',
      'test.tar',
      'test.zip',
    ];
    final fileNameToFileContent = <String, Uint8List>{};
    for (final fileName in testFiles) {
      fileNameToFileContent[fileName] =
          File(p.join(testDirPath, 'res/cat.jpg')).readAsBytesSync();
    }
    final RamFileData ramFileData = RamFileData.outputBuffer();
    final zipEncoder = ZipFileEncoder()
      ..createWithBuffer(
        OutputFileStream.toRamFile(
          RamFileHandle.fromRamFileData(ramFileData),
        ),
      );
    for (final fileEntry in fileNameToFileContent.entries) {
      final name = fileEntry.key;
      final content = fileEntry.value;
      zipEncoder.addArchiveFile(ArchiveFile(name, content.length, content));
    }
    zipEncoder.closeSync();
    final Uint8List zippedBytes = Uint8List(ramFileData.length);
    ramFileData.readIntoSync(zippedBytes, 0, zippedBytes.length);
    final RamFileData readRamFileData = RamFileData.fromBytes(zippedBytes);
    final Archive archive = ZipDecoder().decodeBuffer(
      InputFileStream.withFileBuffer(
        FileBuffer(
          RamFileHandle.fromRamFileData(readRamFileData),
        ),
      ),
    );
    expect(archive.files.length, fileNameToFileContent.length);
    for (int i = 0; i < archive.files.length; i++) {
      final file = archive.files[i];
      final Uint8List? fileContent = fileNameToFileContent[file.name];
      expect(fileContent != null, true,
          reason: 'File content was null for "${file.name}"');
      compareBytes(file.content as List<int>, fileContent as List<int>);
    }
  });

  test('empty file', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/testEmpty.zip');
    await encoder.addFile(File('$testDirPath/res/emptyfile.txt'));
    encoder.closeSync();

    final zipDecoder = ZipDecoder();
    final f = File('$testDirPath/out/testEmpty.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(1));
  });

  _testInputFileStream('stream tar decode', (ifsConstructor) async {
    // Decode a tar from disk to memory
    final stream = await ifsConstructor(p.join(testDirPath, 'res/test2.tar'));
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

  _testInputFileStream('stream zip decode', (ifsConstructor) async {
    // Decode a tar from disk to memory
    final stream = await ifsConstructor(p.join(testDirPath, 'res/test.zip'));
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
    await encoder.addDirectory(Directory('$testDirPath/res/test2'));
    await encoder.close();

    final tarDecoder = TarDecoder();
    final f = File('$testDirPath/out/test3.tar');
    final archive = tarDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(4));
  });

  _testInputOutputFileStream('stream gzip encode', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    final input = await ifsConstructor(p.join(testDirPath, 'res/cat.jpg'));
    final output = await ofsConstructor(p.join(testDirPath, 'out/cat.jpg.gz'));

    final encoder = GZipEncoder();
    encoder.encode(input, output: output);
    await output.close();
  });

  _testInputOutputFileStream('stream gzip decode', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    final input = await ifsConstructor(p.join(testDirPath, 'out/cat.jpg.gz'));
    final output = await ofsConstructor(p.join(testDirPath, 'out/cat.jpg'));

    GZipDecoder().decodeStream(input, output);
    await output.close();
  });

  _testInputOutputFileStream('TarFileEncoder -> GZipEncoder', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.create('$testDirPath/out/example2.tar');
    await encoder.addDirectory(Directory('$testDirPath/res/test2'));
    await encoder.close();

    final input = await ifsConstructor(p.join(testDirPath, 'out/example2.tar'));
    final output =
        await ofsConstructor(p.join(testDirPath, 'out/example2.tgz'));
    GZipEncoder().encode(input, output: output);
    await input.close();
    await output.close();
  });

  test('TarFileEncoder tgz', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    await encoder.tarDirectory(Directory('$testDirPath/res/test2'),
        filename: '$testDirPath/out/example2.tgz', compression: 1);
    await encoder.close();
  });

  test('stream zip encode', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testDirPath/out/example2.zip');
    await encoder.addDirectory(Directory('$testDirPath/res/test2'));
    await encoder.addFile(File('$testDirPath/res/cat.jpg'));
    await encoder.addFile(File('$testDirPath/res/tarurls.txt'));
    encoder.closeSync();

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

  _testInputFileStream('file close', (ifsConstructor) async {
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

    final input = await ifsConstructor(testPath);
    final bs = input.readBytes(50);
    expect(bs.length, 50);
    await input.close();
    await testFile.delete();
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
    await extractArchiveToDisk(
        a, '$testDirPath/out/extractArchiveToDisk_symlink');
  });

  test('extractArchiveToDiskSync symlink', () {
    final f1 = ArchiveFile('test', 3, 'foo'.codeUnits);
    final f2 = ArchiveFile('link', 0, null);
    f2.isSymbolicLink = true;
    f2.nameOfLinkedFile = './../test.tar';
    final a = Archive();
    a.addFile(f1);
    a.addFile(f2);
    extractArchiveToDiskSync(
        a, '$testDirPath/out/extractArchiveToDisk_symlink');
  });

  test('FileHandle', () async {
    final fp = File('$testDirPath/res/zip/zip_bzip2.zip');
    final fh = FileHandle.fromFile(fp);
    final fs = InputFileStream.withFileHandle(fh);
    expect(fs.readByte(), equals(80));
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

  group('$ZipFileEncoder', () {
    test(
      'zipDirectory throws a FormatException when filename is within dir',
      () {
        final encoder = ZipFileEncoder();
        final invalidFilename = p.join(testDirPath, 'res/test2.zip');

        expect(
          () => encoder.zipDirectory(
            Directory(testDirPath),
            filename: invalidFilename,
          ),
          throwsA(
            isA<FormatException>()
                .having(
                  (exception) => exception.message,
                  'message',
                  equals(
                      'filename must not be within the directory being zipped'),
                )
                .having(
                  (exception) => exception.source,
                  'source',
                  equals(invalidFilename),
                ),
          ),
        );
      },
    );

    test(
      'zipDirectoryAsync throws a FormatException when filename is within dir',
      () async {
        final encoder = ZipFileEncoder();
        final invalidFilename = p.join(testDirPath, 'res/test2.zip');

        await expectLater(
          () => encoder.zipDirectoryAsync(
            Directory(testDirPath),
            filename: invalidFilename,
          ),
          throwsA(
            isA<FormatException>()
                .having(
                  (exception) => exception.message,
                  'message',
                  equals(
                      'filename must not be within the directory being zipped'),
                )
                .having(
                  (exception) => exception.source,
                  'source',
                  equals(invalidFilename),
                ),
          ),
        );
      },
    );
  });
}

// ignore_for_file: avoid_print
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_test_util.dart';

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
  fp.openSync(mode: FileMode.writeOnly).closeSync();
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

Future<void> _extractUnderMissingRoot(List<Object> message) {
  final input = message[0] as String;
  final output = message[1] as String;
  final done = message[2] as SendPort;
  final root = p.rootPrefix(output);
  final missing = p.dirname(output);
  return IOOverrides.runZoned(() async {
    try {
      await extractFileToDisk(input, output);
    } catch (_) {}
    done.send(true);
  },
      fseGetTypeSync: (path, followLinks) => p.equals(path, root) ||
              p.isWithin(missing, path) ||
              p.equals(path, missing)
          ? FileSystemEntityType.notFound
          : FileStat.statSync(path).type);
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
  test('zipFileEncoder', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testOutputPath/zipFileEncoder.zip');
    encoder.addDirectorySync(Directory('test/_data/test2'),
        includeDirName: false);
    encoder.closeSync();

    final zip = ZipDecoder().decodeBytes(
        File('$testOutputPath/zipFileEncoder.zip').readAsBytesSync());
    for (final f in zip) {
      expect(f.name.contains('\\'), false, reason: f.name);
    }
  });

  test('inputExtension', () async {
    expect(getInputExtension('test.zip') == '.zip', isTrue);
    expect(getInputExtension('test.ZIP') == '.zip', isTrue);
    expect(getInputExtension('test.tar') == '.tar', isTrue);
    expect(getInputExtension('test.tar.gz') == '.tar.gz', isTrue);
    expect(getInputExtension('test.tar.GZ') == '.tar.gz', isTrue);
    expect(getInputExtension('test.tar.bz2') == '.tar.bz2', isTrue);
    expect(getInputExtension('test.TAR.BZ2') == '.tar.bz2', isTrue);
    expect(getInputExtension('test.tgz') == '.tgz', isTrue);
    expect(getInputExtension('test.TgZ') == '.tgz', isTrue);
    expect(getInputExtension('test.tar.xz') == '.tar.xz', isTrue);
    expect(getInputExtension('test.TAR.xz') == '.tar.xz', isTrue);
    expect(getInputExtension('test.txz') == '.txz', isTrue);
    expect(getInputExtension('TEST.TXZ') == '.txz', isTrue);
    expect(getInputExtension('test.tar.zst') == '.tar.zst', isTrue);
    expect(getInputExtension('test.TAR.ZST') == '.tar.zst', isTrue);
    expect(getInputExtension('test.tzst') == '.tzst', isTrue);
  });

  test('extractFileToDisk zip bzip2', () async {
    final inPath = 'test/_data/zip/zip_bzip2.zip';
    final outPath = '$testOutputPath/extractFileToDisk_zip_bzip2';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 2);
  });

  final testPath = p.join(testOutputPath, 'test_123.bin');
  final testData = Uint8List(120);
  for (var i = 0; i < testData.length; ++i) {
    testData[i] = i;
  }

  // Add an empty directory to test2
  Directory('test/_data/test2/empty').createSync(recursive: true);

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

  test('extractFileToDisk tar.zst', () async {
    final inPath = 'test/_data/zstd/test2.tar.zst';
    final outPath = '$testOutputPath/extractFileToDisk_tzst';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
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
      final input2 =
          InputFileStream.fromFileStream(input, position: 6, length: 5);
      final bs = input2.readBytes(5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });

  test('InputFileStream/OutputFileStream (files)', () {
    var input = InputFileStream(p.join('test/_data/cat.jpg'));
    var output = OutputFileStream(p.join(testOutputPath, 'cat2.jpg'));
    var offset = 0;
    var inputLength = input.length;
    while (!input.isEOS) {
      final bytes = input.readBytes(50);
      if (offset + 50 > inputLength) {
        final remaining = inputLength - offset;
        expect(bytes.length, equals(remaining));
      }
      offset += bytes.length;
      output.writeStream(bytes);
    }
    input.closeSync();
    output.closeSync();

    final aBytes = File(p.join('test/_data/cat.jpg')).readAsBytesSync();
    final bBytes = File(p.join(testOutputPath, 'cat2.jpg')).readAsBytesSync();

    expect(aBytes.length, equals(bBytes.length));
    var same = true;
    for (var i = 0; same && i < aBytes.length; ++i) {
      same = aBytes[i] == bBytes[i];
    }
    expect(same, equals(true));
  });

  test('InputFileStream/OutputFileStream (ram)', () {
    var input = InputFileStream(p.join('test/_data/cat.jpg'));
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
      output.writeStream(bytes);
    }
    input.closeSync();
    output.closeSync();

    final aBytes = File(p.join('test/_data/cat.jpg')).readAsBytesSync();
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
          File(p.join('test/_data/cat.jpg')).readAsBytesSync();
    }
    final RamFileData ramFileData = RamFileData.outputBuffer();
    final zipEncoder = ZipFileEncoder()
      ..createWithStream(
        OutputFileStream.toRamFile(
          RamFileHandle.fromRamFileData(ramFileData),
        ),
      );
    for (final fileEntry in fileNameToFileContent.entries) {
      final name = fileEntry.key;
      final content = fileEntry.value;
      zipEncoder.addArchiveFile(ArchiveFile.bytes(name, content));
    }
    zipEncoder.closeSync();

    final Uint8List zippedBytes = Uint8List(ramFileData.length);
    ramFileData.readIntoSync(zippedBytes, 0, zippedBytes.length);

    final RamFileData readRamFileData = RamFileData.fromBytes(zippedBytes);

    final Archive archive = ZipDecoder().decodeStream(
      InputFileStream.withFileBuffer(
        FileBuffer(
          RamFileHandle.fromRamFileData(readRamFileData),
        ),
      ),
    );

    expect(archive.length, fileNameToFileContent.length);
    for (int i = 0; i < archive.length; i++) {
      final file = archive[i];
      final Uint8List? fileContent = fileNameToFileContent[file.name];
      expect(fileContent != null, true,
          reason: 'File content was null for "${file.name}"');
      compareBytes(file.readBytes()!, fileContent!);
    }
  });

  test('empty file', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testOutputPath/testEmpty.zip');
    await encoder.addFile(File('test/_data/emptyfile.txt'));
    encoder.closeSync();

    final zipDecoder = ZipDecoder();
    final f = File('$testOutputPath/testEmpty.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(1));
  });

  _testInputFileStream('stream tar decode', (ifsConstructor) async {
    // Decode a tar from disk to memory
    final stream = await ifsConstructor(p.join('test/_data/test2.tar'));
    final tarArchive = TarDecoder();
    tarArchive.decodeStream(stream);

    for (final file in tarArchive.files) {
      if (!file.isFile) {
        continue;
      }
      final filename = file.filename;
      try {
        final f = File('$testOutputPath/$filename');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(file.content!.readBytes());
      } catch (e) {
        print(e);
      }
    }

    expect(tarArchive.files.length, equals(4));
  });

  _testInputFileStream('stream zip decode', (ifsConstructor) async {
    // Decode a tar from disk to memory
    final stream = await ifsConstructor(p.join('test/_data/test.zip'));
    final zip = ZipDecoder().decodeStream(stream);

    expect(zip.length, equals(2));
    expect(zip[0].name, equals("a.txt"));
    expect(zip[1].name, equals("cat.jpg"));
    expect(zip[1].size, equals(51662));
  });

  test('stream tar encode', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.open('$testOutputPath/test3.tar');
    await encoder.addDirectory(Directory('test/_data/test2'));
    await encoder.close();

    final tarDecoder = TarDecoder();
    final f = File('$testOutputPath/test3.tar');
    final archive = tarDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(4));
  });

  _testInputOutputFileStream('stream gzip encode', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    final input = await ifsConstructor(p.join('test/_data/cat.jpg'));
    final output = await ofsConstructor(p.join(testOutputPath, 'cat.jpg.gz'));

    final encoder = GZipEncoder();
    encoder.encodeStream(input, output);
    await output.close();
  });

  _testInputOutputFileStream('stream gzip decode', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    final input = await ifsConstructor(p.join(testOutputPath, 'cat.jpg.gz'));
    final output = await ofsConstructor(p.join(testOutputPath, 'cat.jpg'));

    GZipDecoder().decodeStream(input, output);
    await output.close();
  });

  _testInputOutputFileStream('TarFileEncoder -> GZipEncoder', (
    ifsConstructor,
    ofsConstructor,
  ) async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    encoder.create('$testOutputPath/example2.tar');
    await encoder.addDirectory(Directory('test/_data/test2'));
    await encoder.close();

    final input = await ifsConstructor(p.join(testOutputPath, 'example2.tar'));
    final output = await ofsConstructor(p.join(testOutputPath, 'example2.tgz'));
    GZipEncoder().encodeStream(input, output);
    await input.close();
    await output.close();
  });

  test('TarFileEncoder tgz', () async {
    // Encode a directory from disk to disk, no memory
    final encoder = TarFileEncoder();
    await encoder.tarDirectory(Directory('test/_data/test2'),
        filename: '$testOutputPath/example2.tgz', compression: 1);
    await encoder.close();
  });

  test('TarFileEncoder zstd', () async {
    final tarPath = '$testOutputPath/example3.tar';
    final zstPath = '$testOutputPath/example3.tar.zst';
    await TarFileEncoder().tarDirectory(Directory('test/_data/test2'),
        filename: tarPath, compression: TarFileEncoder.store);
    await TarFileEncoder().tarDirectory(Directory('test/_data/test2'),
        filename: zstPath, compression: TarFileEncoder.zstd);

    final tar = File(tarPath).readAsBytesSync();
    final decoded = ZstdDecoder().decodeBytes(File(zstPath).readAsBytesSync(),
        verify: true, throwOnError: true);
    compareBytes(decoded, tar);
  });

  test('TarFileEncoder tgz leaves no files in system temp folder', () async {
    final directory = Directory.systemTemp.createTempSync('archive-tgz-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final scratch = Directory('${directory.path}/scratch')..createSync();

    await IOOverrides.runZoned(() async {
      await TarFileEncoder().tarDirectory(Directory('test/_data/test2'),
          filename: '${directory.path}/example2.tgz',
          compression: TarFileEncoder.gzip);
      expect(scratch.listSync(), isEmpty);
    }, getSystemTempDirectory: () => scratch);
  });

  test('TarFileEncoder tgz deletes temporary folder when filter throws',
      () async {
    final directory = Directory.systemTemp.createTempSync('archive-tgz-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final scratch = Directory('${directory.path}/scratch')..createSync();
    final failure = StateError('filter failed');
    final encoder = TarFileEncoder();
    addTearDown(encoder.close);
    await IOOverrides.runZoned(() async {
      await expectLater(
          encoder.tarDirectory(Directory('test/_data/test2'),
              filename: '${directory.path}/example2.tgz',
              compression: TarFileEncoder.gzip,
              filter: (entity, progress) => throw failure),
          throwsA(same(failure)));
      expect(scratch.listSync(), isEmpty);
    }, getSystemTempDirectory: () => scratch);
  });

  test('stream zip encode async', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testOutputPath/example2.zip');
    await encoder.addDirectory(Directory('test/_data/test2'));
    await encoder.addFile(File('test/_data/cat.jpg'));
    await encoder.addFile(File('test/_data/tarurls.txt'));
    await encoder.close();

    final zipDecoder = ZipDecoder();
    final f = File('$testOutputPath/example2.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(6));
  });

  test('stream zip encode sync', () {
    final encoder = ZipFileEncoder();
    encoder.create('$testOutputPath/example2_sync.zip');
    encoder.addDirectorySync(Directory('test/_data/test2'));
    encoder.addFileSync(File('test/_data/cat.jpg'));
    encoder.addFileSync(File('test/_data/tarurls.txt'));
    encoder.closeSync();

    final zipDecoder = ZipDecoder();
    final f = File('$testOutputPath/example2_sync.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);
    expect(archive.length, equals(6));
  });

  test('ZipFileEncoder with level store writes every entry uncompressed',
      () async {
    final data = File('test/_data/tarurls.txt');
    final path = '$testOutputPath/example_store.zip';
    final encoder = ZipFileEncoder()..create(path, level: ZipFileEncoder.store);
    await encoder.addFile(data, 'async.txt');
    encoder.addFileSync(data, 'sync.txt');
    await encoder.addDirectory(Directory('test/_data/test2'));
    final added = ArchiveFile.string('string.txt', 'x' * 5000);
    encoder.addArchiveFile(added);
    await encoder.close();
    expect(added.compression, isNull);

    final decoder = ZipDecoder();
    final archive =
        decoder.decodeBytes(File(path).readAsBytesSync(), verify: true);
    for (final header in decoder.directory.fileHeaders) {
      if (!header.filename.endsWith('/')) {
        expect(header.compressionMethod, 0, reason: header.filename);
      }
    }
    expect(archive.findFile('async.txt')!.content, data.readAsBytesSync());
    expect(archive.findFile('sync.txt')!.content, data.readAsBytesSync());
    expect(archive.findFile('string.txt')!.content, List.filled(5000, 0x78));
  });

  test('ZipFileEncoder stores only file added with level store', () async {
    final data = File('test/_data/tarurls.txt');
    final path = '$testOutputPath/example_store_one.zip';
    final encoder = ZipFileEncoder()..create(path);
    await encoder.addFile(data, 'stored.txt', ZipFileEncoder.store);
    await encoder.addFile(data, 'deflated.txt');
    await encoder.close();

    final decoder = ZipDecoder()
      ..decodeBytes(File(path).readAsBytesSync(), verify: true);
    final methods = {
      for (final header in decoder.directory.fileHeaders)
        header.filename: header.compressionMethod
    };
    expect(methods, {'stored.txt': 0, 'deflated.txt': 8});
  });

  test('stream zip encode levels', () async {
    final encoder = ZipFileEncoder();
    encoder.create('$testOutputPath/example3.zip');
    await encoder.addFile(File('test/_data/tarurls.txt'), "tarurls_0.txt", 0);
    await encoder.addFile(File('test/_data/tarurls.txt'), "tarurls_1.txt", 1);
    await encoder.addFile(File('test/_data/tarurls.txt'), "tarurls_6.txt", 6);
    encoder.closeSync();

    final zipDecoder = ZipDecoder();
    final f = File('$testOutputPath/example3.zip');
    final archive = zipDecoder.decodeBytes(f.readAsBytesSync(), verify: true);

    // Ensure that higher compression levels produce smaller files
    final f0 = archive.files.firstWhere((o) => o.name == "tarurls_0.txt");
    final f1 = archive.files.firstWhere((o) => o.name == "tarurls_1.txt");
    final f6 = archive.files.firstWhere((o) => o.name == "tarurls_6.txt");
    assert(f1.rawContent!.length < f0.rawContent!.length);
    assert(f6.rawContent!.length < f1.rawContent!.length);
  });

  test('decode_empty_directory', () {
    final zip = ZipDecoder();
    final archive =
        zip.decodeBytes(File('test/_data/test2.zip').readAsBytesSync());
    expect(archive.length, 4);
  });

  test('create_archive_from_directory', () {
    final dir = Directory('test/_data/test2');
    final archive = createArchiveFromDirectory(dir);
    expect(archive.length, equals(4));
    final encoder = ZipEncoder();

    final bytes = encoder.encodeBytes(archive);
    File('$testOutputPath/test2_.zip')
      ..openSync(mode: FileMode.write)
      ..writeAsBytesSync(bytes);

    final zipDecoder = ZipDecoder();
    final archive2 = zipDecoder.decodeBytes(bytes, verify: true);
    expect(archive2.length, equals(4));
  });

  _testInputFileStream('file close', (ifsConstructor) async {
    final testPath = p.join(testOutputPath, 'test2.bin');
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
    final inPath = 'test/_data/test2.tar';
    final outPath = '$testOutputPath/extractFileToDisk_tar';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk keeps symlink chains inside output directory',
      () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final outside = Directory('${directory.path}/outside')..createSync();
    final file = File('${outside.path}/payload.txt')..writeAsStringSync('keep');
    final archive = Archive()
      ..add(ArchiveFile.directory('safe'))
      ..add(ArchiveFile.symlink('foo/bar/baz', '../../safe'))
      ..add(ArchiveFile.symlink('foo/bar/baz/alias', '../../outside'))
      ..add(ArchiveFile.string('foo/bar/baz/alias/payload.txt', 'changed'));
    final input = File('${directory.path}/input.tar')
      ..writeAsBytesSync(TarEncoder().encodeBytes(archive));

    try {
      await extractFileToDisk(input.path, '${directory.path}/out');
    } on ArchiveException {
      // Rejecting the archive must leave the outside file intact
    }
    expect(file.readAsStringSync(), 'keep');
  }, testOn: '!windows');

  test('extractFileToDisk tar.gz', () async {
    final inPath = 'test/_data/test2.tar.gz';
    final outPath = '$testOutputPath/extractFileToDisk_tgz';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk tar.tbz', () async {
    final inPath = 'test/_data/test2.tar.bz2';
    final outPath = '$testOutputPath/extractFileToDisk_tbz';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk extracts tar.zst', () async {
    final inPath = 'test/_data/test2.tar.zst';
    final outPath = '$testOutputPath/extractFileToDisk_tar_zst';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  test('extractFileToDisk extracts tzst', () async {
    final inPath = 'test/_data/test2.tzst';
    final outPath = '$testOutputPath/extractFileToDisk_tzst';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 4);
  });

  // The header picks the format. The name counts only when the header is
  // unknown
  test('extractFileToDisk detects format from header, not file name', () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final gz = File('test/_data/test2.tar.gz').readAsBytesSync();
    for (final name in ['misnamed.zip', 'noextension']) {
      final input = File('${directory.path}/$name')..writeAsBytesSync(gz);
      final output = '${directory.path}/out_$name';
      await extractFileToDisk(input.path, output);
      expect(Directory(output).listSync(recursive: true).length, 4);
    }
  });

  test('extractFileToDisk extracts tar whose filenames start with codec magic',
      () async {
    const name = 'BZh11AY&SY.txt';
    final bytes = TarEncoder().encodeBytes(
        Archive()..add(ArchiveFile.string(name, 'archive content')));
    final archive = TarDecoder().decodeBytes(bytes, verify: true);
    expect(archive.files.single.name, name);
    expect(archive.files.single.content, 'archive content'.codeUnits);

    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final input = File('${directory.path}/valid.tar')..writeAsBytesSync(bytes);
    final output = '${directory.path}/out';
    await extractFileToDisk(input.path, output);
    expect(File('$output/$name').readAsStringSync(), 'archive content');
  });

  // The file is a gzip with no tar inside. Nothing from it may reach the
  // output directory
  test('extractFileToDisk throws on gzip without tar inside', () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final text =
        Uint8List.fromList(List<int>.generate(1 << 20, (i) => 0x41 + (i % 26)));
    for (final name in ['dump.sql.gz', 'dump.tar.gz']) {
      final input = File('${directory.path}/$name')
        ..writeAsBytesSync(GZipEncoder().encodeBytes(text));
      for (final strict in [true, false]) {
        final output = '${directory.path}/out-$name-$strict';
        await expectLater(
            extractFileToDisk(input.path, output, throwOnError: strict),
            throwsA(isA<ArgumentError>()),
            reason: '$name throwOnError $strict');
        final left = Directory(output).existsSync()
            ? Directory(output).listSync()
            : <FileSystemEntity>[];
        expect(left, isEmpty, reason: '$name throwOnError $strict');
      }
    }
  });

  test('extractFileToDisk throws on truncated tar.zst frame', () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final archive = Archive()
      ..add(ArchiveFile('first.bin', 3, [1, 2, 3]))
      ..add(ArchiveFile('second.bin', 3, [4, 5, 6]));
    final tar = TarEncoder().encodeBytes(archive);
    final first =
        ZstdEncoder().encodeBytes(Uint8List.sublistView(tar, 0, 1024));
    final last = ZstdEncoder()
        .encodeBytes(Uint8List.sublistView(tar, 1024), checksum: true);
    final input = File('${directory.path}/input.tar.zst')
      ..writeAsBytesSync([...first, ...last]);
    final validOutput = '${directory.path}/valid';
    await extractFileToDisk(input.path, validOutput);
    expect(File('$validOutput/first.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('$validOutput/second.bin').readAsBytesSync(), [4, 5, 6]);

    final truncated = [...first, ...last.sublist(0, last.length - 1)];
    final partial = OutputMemoryStream();
    expect(ZstdDecoder().decodeStream(InputMemoryStream(truncated), partial),
        isFalse);
    expect(TarDecoder().decodeBytes(partial.getBytes()).length, 2);
    input.writeAsBytesSync(truncated);
    await expectLater(
        extractFileToDisk(input.path, '${directory.path}/truncated',
            throwOnError: true),
        throwsA(isA<ArchiveException>()));

    final lenient = '${directory.path}/lenient';
    await extractFileToDisk(input.path, lenient);
    expect(File('$lenient/first.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('$lenient/second.bin').readAsBytesSync(), [4, 5, 6]);
  });

  // pbzip2 writes one bzip2 stream per block and bzip2 -d reads them all
  test(
      'extractFileToDisk reads every tar.bz2 stream and throws on truncated one',
      () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final archive = Archive()
      ..add(ArchiveFile('first.bin', 3, [1, 2, 3]))
      ..add(ArchiveFile('second.bin', 3, [4, 5, 6]));
    final tar = TarEncoder().encodeBytes(archive);
    final first =
        BZip2Encoder().encodeBytes(Uint8List.sublistView(tar, 0, 1024));
    final last = BZip2Encoder().encodeBytes(Uint8List.sublistView(tar, 1024));
    final input = File('${directory.path}/input.tar.bz2')
      ..writeAsBytesSync([...first, ...last]);
    final validOutput = '${directory.path}/valid';
    await extractFileToDisk(input.path, validOutput);
    expect(File('$validOutput/first.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('$validOutput/second.bin').readAsBytesSync(), [4, 5, 6]);

    final truncated = [...first, ...last.sublist(0, last.length - 1)];
    expect(
        BZip2Decoder()
            .decodeStream(InputMemoryStream(truncated), OutputMemoryStream()),
        isFalse);
    input.writeAsBytesSync(truncated);
    await expectLater(
        extractFileToDisk(input.path, '${directory.path}/truncated',
            throwOnError: true),
        throwsA(isA<ArchiveException>()));

    final lenient = '${directory.path}/lenient';
    await extractFileToDisk(input.path, lenient);
    expect(File('$lenient/first.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('$lenient/second.bin').readAsBytesSync(), [4, 5, 6]);
  });

  test('extractFileToDisk deletes temporary tar files after failure', () async {
    final directory = Directory.systemTemp.createTempSync('archive-cleanup-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final scratch = Directory('${directory.path}/scratch')..createSync();
    final first = ZstdEncoder().encodeBytes(Uint8List(1024));
    final last = ZstdEncoder().encodeBytes(Uint8List(512));
    final input = File('${directory.path}/input.tar.zst')
      ..writeAsBytesSync([...first, ...last.sublist(0, last.length - 1)]);

    await IOOverrides.runZoned(() async {
      await expectLater(
          extractFileToDisk(input.path, '${directory.path}/output',
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(scratch.listSync(), isEmpty);

      await extractFileToDisk(input.path, '${directory.path}/lenient');
      expect(scratch.listSync(), isEmpty);
    }, getSystemTempDirectory: () => scratch);
  });

  test('extractFileToDisk returns when output drive does not exist', () async {
    final directory = Directory.systemTemp.createTempSync('archive-extract-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final input = File('${directory.path}/input.zip')
      ..writeAsBytesSync(ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'a'))));
    final output = p.join(
        p.rootPrefix(directory.absolute.path), 'archive-missing-drive', 'out');
    final done = ReceivePort();
    final isolate = await Isolate.spawn(
        _extractUnderMissingRoot, [input.path, output, done.sendPort]);
    addTearDown(() {
      isolate.kill(priority: Isolate.immediate);
      done.close();
    });
    await expectLater(
        done.first.timeout(const Duration(seconds: 10)), completes);
  });

  test('extractFileToDisk zip', () async {
    final inPath = 'test/_data/test.zip';
    final outPath = '$testOutputPath/extractFileToDisk_zip';
    final dir = Directory(outPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    await extractFileToDisk(inPath, outPath);

    final files = dir.listSync(recursive: true);
    expect(files.length, 2);
  });

  // bsdtar makes a real hard link, Python tarfile and 7-Zip 26 write a copy
  test('extractFileToDisk writes hard link with content of its target',
      () async {
    final root = Directory.systemTemp.createTempSync('archive-extract-path-');
    addTearDown(() => root.deleteSync(recursive: true));
    final out = OutputMemoryStream();
    final tar = TarEncoder()..start(out);
    tar.add(ArchiveFile.string('usr/bin/gcc', 'compiler'));
    (TarFile()
          ..filename = 'usr/bin/gcc-13'
          ..typeFlag = TarFile.hardLink
          ..nameOfLinkedFile = 'usr/bin/gcc'
          ..mode = 0x1ed)
        .write(out);
    tar.finish();
    final input = File(p.join(root.path, 'hard.tar'))
      ..writeAsBytesSync(out.getBytes());
    final output = p.join(root.path, 'out');
    await extractFileToDisk(input.path, output);
    expect(File(p.join(output, 'usr', 'bin', 'gcc-13')).readAsStringSync(),
        'compiler');
  }, testOn: '!windows');

  test('tar hard link encoded into zip keeps content of its target', () async {
    final root = Directory.systemTemp.createTempSync('archive-extract-path-');
    addTearDown(() => root.deleteSync(recursive: true));
    final out = OutputMemoryStream();
    final tar = TarEncoder()..start(out);
    tar.add(ArchiveFile.string('usr/bin/gcc', 'compiler'));
    (TarFile()
          ..filename = 'usr/bin/gcc-13'
          ..typeFlag = TarFile.hardLink
          ..nameOfLinkedFile = 'usr/bin/gcc'
          ..mode = 0x1ed)
        .write(out);
    tar.finish();
    final zip = ZipEncoder()
        .encodeBytes(TarDecoder().decodeBytes(out.getBytes(), verify: true));
    final input = File(p.join(root.path, 'hard.zip'))..writeAsBytesSync(zip);
    final output = p.join(root.path, 'out');
    await extractFileToDisk(input.path, output);
    final link = File(p.join(output, 'usr', 'bin', 'gcc-13'));
    expect(link.existsSync(), isTrue);
    expect(link.readAsStringSync(), 'compiler');
  }, testOn: '!windows');

  for (final method in ['sync', 'async', 'tar', 'zip']) {
    Future<void> extract(Archive archive, String output, String root,
        {bool allowAbsoluteSymlinks = false}) async {
      if (method == 'sync') {
        extractArchiveToDiskSync(archive, output,
            allowAbsoluteSymlinks: allowAbsoluteSymlinks);
      } else if (method == 'async') {
        await extractArchiveToDisk(archive, output,
            allowAbsoluteSymlinks: allowAbsoluteSymlinks);
      } else {
        final input = File(p.join(root, 'input.$method'))
          ..writeAsBytesSync(method == 'tar'
              ? TarEncoder().encodeBytes(archive)
              : ZipEncoder().encodeBytes(archive));
        await extractFileToDisk(input.path, output,
            allowAbsoluteSymlinks: allowAbsoluteSymlinks);
      }
    }

    // bsdtar, Python tarfile and 7-Zip 26 also strip leading slashes
    test('$method strips leading slashes from entry names', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()..add(ArchiveFile.string('/etc/rc.d/abs.txt', 'abs')),
          output,
          root.path);
      expect(File(p.join(output, 'etc', 'rc.d', 'abs.txt')).readAsStringSync(),
          'abs');
    });

    test('$method strips Windows path prefix from entry names', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()
            ..add(ArchiveFile.string(r'\\?\C:\dir\a.txt', 'a'))
            ..add(ArchiveFile.string('ok.txt', 'ok')),
          output,
          root.path);
      final name = method == 'zip' ? p.join('dir', 'a.txt') : r'dir\a.txt';
      expect(File(p.join(output, name)).readAsStringSync(), 'a');
      expect(File(p.join(output, 'ok.txt')).readAsStringSync(), 'ok');
    });

    test('$method creates empty directory entry', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()
            ..add(ArchiveFile.directory('empty/'))
            ..add(ArchiveFile.string('full/a.txt', 'a')),
          output,
          root.path);
      expect(Directory(p.join(output, 'empty')).existsSync(), isTrue);
      expect(File(p.join(output, 'full', 'a.txt')).readAsStringSync(), 'a');
    });

    test('$method creates directory at path of file from earlier entry',
        () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()
            ..add(ArchiveFile.directory('a/'))
            ..add(ArchiveFile.string('a/b', 'file'))
            ..add(ArchiveFile.directory('a/b/'))
            ..add(ArchiveFile.string('a/b/c', 'c')),
          output,
          root.path);
      expect(File(p.join(output, 'a', 'b', 'c')).readAsStringSync(), 'c');
    });

    // Python tarfile default filter and 7-Zip 26 also keep such link out,
    // bsdtar and Python filter='tar' create it as allowAbsoluteSymlinks does
    test('$method creates absolute symlinks only when allowed', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final archive = Archive()
        ..add(ArchiveFile.symlink('abs', '/usr/share/missing'));
      final strict = p.join(root.path, 'strict');
      await extract(archive, strict, root.path);
      expect(
          FileSystemEntity.typeSync(p.join(strict, 'abs'), followLinks: false),
          FileSystemEntityType.notFound);
      final allowed = p.join(root.path, 'allowed');
      await extract(archive, allowed, root.path, allowAbsoluteSymlinks: true);
      expect(Link(p.join(allowed, 'abs')).targetSync(), '/usr/share/missing');
    }, testOn: '!windows');

    test('$method resolves output symlinks before parent path components',
        () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'nested', 'target'))
          .createSync(recursive: true);
      final actual = p.join(root.path, 'nested', 'out');
      Directory(p.join(actual, 'link')).createSync(recursive: true);
      Directory(p.join(root.path, 'out')).createSync();
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      final sentinel = File(p.join(outside.path, 'payload'))
        ..writeAsStringSync('keep');
      Link(p.join(root.path, 'alias')).createSync(p.join('nested', 'target'));
      Link(p.join(root.path, 'out', 'link'))
          .createSync(p.join('..', 'outside'));
      final output = p.join(root.path, 'alias', '..', 'out');
      expect(Directory(output).resolveSymbolicLinksSync(),
          Directory(actual).resolveSymbolicLinksSync());
      final archive = Archive()
        ..add(ArchiveFile.string('link/payload', 'new'))
        ..add(ArchiveFile.string('safe/é.txt', 'safe'))
        ..add(ArchiveFile.symlink('link/ref', '../safe/é.txt'));

      await extract(archive, output, root.path);

      expect(File(p.join(actual, 'link', 'payload')).readAsStringSync(), 'new');
      expect(File(p.join(actual, 'link', 'ref')).readAsStringSync(), 'safe');
      expect(sentinel.readAsStringSync(), 'keep');
    }, testOn: '!windows');

    // bsdtar and Python tarfile also create a link whose target is a link
    // not yet resolvable, 7-Zip 26 drops it
    test('$method keeps dangling link to dangling link', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()
            ..add(ArchiveFile.symlink('lib/liblber.so', 'liblber.so.2.0.200'))
            ..add(ArchiveFile.symlink('lib/liblber.so.2', 'liblber.so'))
            ..add(ArchiveFile.string('lib/liblber.so.2.0.200', 'library')),
          output,
          root.path);
      expect(Link(p.join(output, 'lib', 'liblber.so.2')).targetSync(),
          'liblber.so');
      expect(File(p.join(output, 'lib', 'liblber.so.2')).readAsStringSync(),
          'library');
    }, testOn: '!windows');

    // bsdtar and Python tarfile also keep link text as the archive has it
    test('$method writes link target text unchanged from archive', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      await extract(
          Archive()
            ..add(ArchiveFile.string('t.txt', 't'))
            ..add(ArchiveFile.symlink('d/e/rel', '.././../t.txt')),
          output,
          root.path);
      expect(
          Link(p.join(output, 'd', 'e', 'rel')).targetSync(), '.././../t.txt');
      expect(File(p.join(output, 'd', 'e', 'rel')).readAsStringSync(), 't');
    }, testOn: '!windows');

    // bsdtar gives same tree: later entry replaces file or link at its path
    test('$method replaces file left at path by earlier entry', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      final archive = Archive()
        ..add(ArchiveFile.string('b.txt', 'b'))
        ..add(ArchiveFile.string('a.txt', 'a'))
        ..add(ArchiveFile.symlink('./a.txt', 'b.txt'))
        ..add(ArchiveFile.symlink('c.txt', 'b.txt'))
        ..add(ArchiveFile.string('./c.txt', 'c'))
        ..add(ArchiveFile.symlink('d', 'z.txt'))
        ..add(ArchiveFile.symlink('./d', 'b.txt'))
        ..add(ArchiveFile.string('z.txt', 'z'));

      await extract(archive, output, root.path);

      expect(Link(p.join(output, 'd')).targetSync(), 'b.txt');
      expect(Link(p.join(output, 'a.txt')).targetSync(), 'b.txt');
      expect(FileSystemEntity.isLinkSync(p.join(output, 'c.txt')), isFalse);
      expect(File(p.join(output, 'c.txt')).readAsStringSync(), 'c');
      expect(File(p.join(output, 'b.txt')).readAsStringSync(), 'b');
    }, testOn: '!windows');

    test(
        '$method rejects link targets that escape output directory through links',
        () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      final secret = File(p.join(root.path, 'secret.txt'))
        ..writeAsStringSync('outside');
      await extract(
          Archive()
            ..add(ArchiveFile.string('sub/file.txt', 'inside'))
            ..add(ArchiveFile.symlink('nested/hop', '../sub'))
            ..add(ArchiveFile.symlink('escape', 'nested/hop/../../secret.txt')),
          output,
          root.path);

      expect(File(p.join(output, 'nested/hop/file.txt')).readAsStringSync(),
          'inside');
      expect(
          FileSystemEntity.typeSync(p.join(output, 'escape'),
              followLinks: false),
          FileSystemEntityType.notFound);
      expect(secret.readAsStringSync(), 'outside');
    }, testOn: '!windows');

    test('$method rejects escaping path that comes before its link', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = p.join(root.path, 'out');
      final secret = File(p.join(root.path, 'secret.txt'))
        ..writeAsStringSync('outside');
      await extract(
          Archive()
            ..add(ArchiveFile.string('sub/file.txt', 'inside'))
            ..add(ArchiveFile.symlink('escape', 'nested/hop/../../secret.txt'))
            ..add(ArchiveFile.symlink('nested/hop', '../sub')),
          output,
          root.path);

      expect(File(p.join(output, 'nested/hop/file.txt')).readAsStringSync(),
          'inside');
      expect(
          FileSystemEntity.typeSync(p.join(output, 'escape'),
              followLinks: false),
          FileSystemEntityType.notFound);
      expect(secret.readAsStringSync(), 'outside');
    }, testOn: '!windows');

    test('$method checks links against physical output directory', () async {
      final root = Directory.systemTemp.createTempSync('archive-extract-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'nested', 'target'))
          .createSync(recursive: true);
      final actual = p.join(root.path, 'nested', 'out');
      Directory(actual).createSync();
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      final sentinel = File(p.join(outside.path, 'payload'))
        ..writeAsStringSync('keep');
      Link(p.join(root.path, 'alias')).createSync(p.join('nested', 'target'));
      for (final name in ['escape', 'broken', 'loop']) {
        Directory(p.join(root.path, 'out', name)).createSync(recursive: true);
      }
      Link(p.join(actual, 'escape')).createSync(p.join('..', '..', 'outside'));
      Link(p.join(actual, 'broken')).createSync('missing');
      Link(p.join(actual, 'loop')).createSync('loop');
      final output = p.join(root.path, 'alias', '..', 'out');
      await extract(
          Archive()..add(ArchiveFile.string('escape/payload', 'changed')),
          output,
          root.path);
      expect(sentinel.readAsStringSync(), 'keep');

      final archive = Archive()
        ..add(ArchiveFile.string('broken/payload', 'changed'))
        ..add(ArchiveFile.string('loop/payload', 'changed'))
        ..add(ArchiveFile.symlink('indirect', 'escape/payload'))
        ..add(ArchiveFile.string('safe/payload', 'safe'))
        ..add(ArchiveFile.symlink('safe/ref', 'payload'));

      await extract(archive, output, root.path);

      expect(sentinel.readAsStringSync(), 'keep');
      expect(File(p.join(actual, 'safe', 'ref')).readAsStringSync(), 'safe');
      expect(File(p.join(actual, 'missing', 'payload')).existsSync(), isFalse);
      expect(
          FileSystemEntity.typeSync(p.join(actual, 'indirect'),
              followLinks: false),
          FileSystemEntityType.notFound);
      expect(Link(p.join(actual, 'broken')).targetSync(), 'missing');
      expect(Link(p.join(actual, 'loop')).targetSync(), 'loop');
    }, testOn: '!windows');
  }

  test('extractArchiveToDisk symlink', () async {
    final f1 = ArchiveFile.string('test', 'foo');
    final f2 = ArchiveFile.symlink('link', './../test.tar');
    final a = Archive();
    a.add(f1);
    a.add(f2);
    await extractArchiveToDisk(
        a, '$testOutputPath/extractArchiveToDisk_symlink');
  });

  test('extractArchiveToDiskSync symlink', () {
    final f1 = ArchiveFile.string('test', 'foo');
    final f2 = ArchiveFile.symlink('link', './../test.tar');
    final a = Archive();
    a.add(f1);
    a.add(f2);
    extractArchiveToDiskSync(a, '$testOutputPath/extractArchiveToDisk_symlink');
  });

  for (final method in ['sync', 'async']) {
    test('$method of decoded tar writes same files on second extraction',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final data = Uint8List.fromList(List.generate(3000, (i) => i * 7 % 251));
      final tar = File(p.join(directory.path, 'a.tar'))
        ..writeAsBytesSync(TarEncoder()
            .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', data))));
      final input = InputFileStream(tar.path);
      addTearDown(input.closeSync);
      final archive = TarDecoder().decodeStream(input);
      for (final name in ['one', 'two']) {
        final out = p.join(directory.path, name);
        if (method == 'sync') {
          extractArchiveToDiskSync(archive, out);
        } else {
          await extractArchiveToDisk(archive, out);
        }
        expect(File(p.join(out, 'a.bin')).readAsBytesSync(), data,
            reason: name);
      }
    });
  }

  test('FileHandle', () async {
    final fh = FileHandle('test/_data/zip/zip_bzip2.zip');
    final fs = InputFileStream.withFileHandle(fh);
    expect(fs.readByte(), equals(80));
  });

  test('zipDirectory stops and rethrows when onProgress throws', () async {
    final root = Directory.systemTemp.createTempSync('archive-zip-progress-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = p.join(root.path, 'src');
    generateDataDirectory(source, fileSize: 1024, numFiles: 5);
    final zipPath = p.join(root.path, 'out.zip');
    var calls = 0;
    await expectLater(
        ZipFileEncoder().zipDirectory(Directory(source), filename: zipPath,
            onProgress: (_) {
          calls++;
          throw StateError('progress failed');
        }),
        throwsStateError);
    expect(calls, 1);
    expect(
        ZipDecoder()
            .decodeBytes(File(zipPath).readAsBytesSync(), verify: true)
            .files
            .where((f) => f.isFile),
        hasLength(1));
  });

  test('addDirectorySync stops and rethrows when onProgress throws', () {
    final root = Directory.systemTemp.createTempSync('archive-zip-progress-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = p.join(root.path, 'src');
    generateDataDirectory(source, fileSize: 1024, numFiles: 5);
    final encoder = ZipFileEncoder()..create(p.join(root.path, 'out.zip'));
    var calls = 0;
    expect(
        () => encoder.addDirectorySync(Directory(source), onProgress: (_) {
              calls++;
              throw StateError('progress failed');
            }),
        throwsStateError);
    expect(calls, 1);
    encoder.closeSync();
  });

  test('zip directory', () async {
    final tmpPath = '$testOutputPath/test_zip_dir';

    generateDataDirectory(tmpPath, fileSize: 1024, numFiles: 5);

    final inPath = '$testOutputPath/test_zip_dir_2.zip';
    final outPath = '$testOutputPath/test_zip_dir_2';

    var count = 0;
    final encoder = ZipFileEncoder();
    await encoder.zipDirectory(Directory(tmpPath), level: 0, filename: inPath,
        onProgress: (double x) {
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
        Directory('$testOutputPath/test_zip_dir_2').listSync(recursive: true);
    expect(dstFiles.length, equals(srcFiles.length));
    encoder.closeSync();
  });

  test('zip directory (too many open files regression)', () async {
    final tmpPath = '$testOutputPath/test_zip_dir_3';

    generateDataDirectory(tmpPath, fileSize: 1024, numFiles: 2000);

    final inPath = '$testOutputPath/test_zip_dir_3.zip';
    final outPath = '$testOutputPath/test_zip_dir_3_out';

    final encoder = ZipFileEncoder();
    await encoder.zipDirectory(Directory(tmpPath));

    await extractFileToDisk(inPath, outPath);

    final srcFiles = Directory(tmpPath).listSync(recursive: true);
    final dstFiles = Directory(outPath).listSync(recursive: true);
    expect(dstFiles.length, equals(srcFiles.length));
    encoder.closeSync();
  });

  group('$ZipFileEncoder', () {
    test(
      'zipDirectory throws a FormatException when filename is within dir',
      () async {
        final encoder = ZipFileEncoder();
        final invalidFilename = p.join('test/_data/test2.zip');

        expect(
          () => encoder.zipDirectory(
            Directory('test'),
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
        final invalidFilename = p.join('test/_data/test2.zip');

        await expectLater(
          () => encoder.zipDirectory(
            Directory('test/_data'),
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

  group('extractFileToDisk after failure part way through', () {
    test('rethrows original error and deletes temporary tar', () async {
      final scratch = Directory.systemTemp.createTempSync('extract_failure');
      addTearDown(() => scratch.deleteSync(recursive: true));
      int leftovers() => Directory.systemTemp
          .listSync()
          .where((entry) => p.basename(entry.path).startsWith('dart_archive'))
          .length;
      final before = leftovers();

      final archive = Archive()
        ..add(ArchiveFile.string('f0.txt', 'x' * 4096))
        // A path under a name that is already a file, so the write fails
        ..add(ArchiveFile.string('f0.txt/inner.txt', 'boom'))
        ..add(ArchiveFile.string('f1.txt', 'y' * 4096));
      final path = p.join(scratch.path, 'a.tar.gz');
      File(path).writeAsBytesSync(
          GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)));

      await expectLater(extractFileToDisk(path, p.join(scratch.path, 'out')),
          throwsA(isA<FileSystemException>()));
      expect(leftovers(), before);
    });
  });

  group('extractFileToDisk on damaged archive', () {
    Uint8List content() => Uint8List.fromList(
        List<int>.generate(5000, (i) => (i * 131 + (i >> 7)) & 0xff));

    test('zip entry that cannot be decoded leaves no file on disk', () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('b.bin', content())
          ..compression = CompressionType.bzip2));
      const localHeader = 30;
      const bzipSignature = 4;
      zip[localHeader + 'b.bin'.length + bzipSignature] ^= 0x55;
      expect(ZipDecoder().decodeBytes(zip).first.content, isEmpty);
      expect(
          () => ZipDecoder().decodeBytes(zip, throwOnError: true).first.content,
          throwsA(isA<ArchiveException>()));
      final input = File(p.join(directory.path, 'damaged.zip'))
        ..writeAsBytesSync(zip);

      final out = p.join(directory.path, 'out');
      await extractFileToDisk(input.path, out);
      expect(File(p.join(out, 'b.bin')).existsSync(), isFalse);

      final strict = p.join(directory.path, 'strict');
      await expectLater(
          extractFileToDisk(input.path, strict, throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(File(p.join(strict, 'b.bin')).existsSync(), isFalse);

      final archive = ZipDecoder().decodeBytes(zip, throwOnError: true);
      for (final sync in [false, true]) {
        final lenient = p.join(directory.path, 'lenient_$sync');
        final thrown = p.join(directory.path, 'thrown_$sync');
        if (sync) {
          extractArchiveToDiskSync(archive, lenient);
          expect(
              () =>
                  extractArchiveToDiskSync(archive, thrown, throwOnError: true),
              throwsA(isA<ArchiveException>()));
        } else {
          await extractArchiveToDisk(archive, lenient);
          await expectLater(
              extractArchiveToDisk(archive, thrown, throwOnError: true),
              throwsA(isA<ArchiveException>()));
        }
        expect(File(p.join(thrown, 'b.bin')).existsSync(), isFalse,
            reason: 'sync $sync');
        expect(File(p.join(lenient, 'b.bin')).existsSync(), isFalse,
            reason: 'sync $sync');
      }
    });

    test(
        'extractArchiveToDisk verify and throwOnError apply to archive decoded without them',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('b.bin', content())
          ..compression = CompressionType.bzip2));
      const localHeader = 30;
      const bzipSignature = 4;
      zip[localHeader + 'b.bin'.length + bzipSignature] ^= 0x55;
      for (final sync in [false, true]) {
        final lenient = p.join(directory.path, 'lenient_$sync');
        final thrown = p.join(directory.path, 'thrown_$sync');
        final archive = ZipDecoder().decodeBytes(zip);
        if (sync) {
          extractArchiveToDiskSync(archive, lenient);
          expect(
              () =>
                  extractArchiveToDiskSync(archive, thrown, throwOnError: true),
              throwsA(isA<ArchiveException>()));
        } else {
          await extractArchiveToDisk(archive, lenient);
          await expectLater(
              extractArchiveToDisk(archive, thrown, throwOnError: true),
              throwsA(isA<ArchiveException>()));
        }
        expect(File(p.join(thrown, 'b.bin')).existsSync(), isFalse,
            reason: 'sync $sync');
        expect(File(p.join(lenient, 'b.bin')).existsSync(), isFalse,
            reason: 'sync $sync');
      }
    });

    test('verify throws on wrong CRC that extraction without flags accepts',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('s.bin', content())
          ..compression = CompressionType.none));
      const localHeader = 30;
      const utField = 9;
      zip[localHeader + 's.bin'.length + utField + 100] ^= 0x55;
      final input = File(p.join(directory.path, 'crc.zip'))
        ..writeAsBytesSync(zip);

      final out = p.join(directory.path, 'out');
      await extractFileToDisk(input.path, out);
      expect(File(p.join(out, 's.bin')).lengthSync(), content().length);

      final checked = p.join(directory.path, 'checked');
      await expectLater(
          extractFileToDisk(input.path, checked,
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
      expect(File(p.join(checked, 's.bin')).existsSync(), isFalse);
    });

    test('complete entries of zip with wrong end record are extracted',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.bin', content()))
        ..add(ArchiveFile.bytes('b.bin', content())));
      final eocd = zip.length - 22;
      for (final (name, at) in [
        ('count', eocd + 10),
        ('comment', eocd + 20),
      ]) {
        final damaged = Uint8List.fromList(zip)..[at] = 5;
        expect(ZipDecoder().decodeBytes(damaged).files.map((f) => f.name),
            ['a.bin', 'b.bin'],
            reason: name);
        final input = File(p.join(directory.path, '$name.zip'))
          ..writeAsBytesSync(damaged);
        final out = p.join(directory.path, name);
        await extractFileToDisk(input.path, out);
        for (final file in ['a.bin', 'b.bin']) {
          final extracted = File(p.join(out, file));
          expect(extracted.existsSync(), isTrue, reason: '$name $file');
          expect(extracted.readAsBytesSync(), content(), reason: '$name $file');
        }
      }
    });

    test('callback receives every entry of zip with wrong end record',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.bin', content()))
        ..add(ArchiveFile.bytes('b.bin', content())));
      final damaged = Uint8List.fromList(zip)..[zip.length - 22 + 10] = 5;
      final input = File(p.join(directory.path, 'count.zip'))
        ..writeAsBytesSync(damaged);
      final seen = <String>[];
      await extractFileToDisk(input.path, p.join(directory.path, 'out'),
          callback: (file) => seen.add(file.name));
      expect(File(p.join(directory.path, 'out', 'b.bin')).existsSync(), isTrue);
      expect(seen, ['a.bin', 'b.bin']);
    });

    test('callback receives each entry once when zip link cannot be read',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.bin', content()))
        ..add(ArchiveFile.string('link', 'a.bin' * 600))
        ..add(ArchiveFile.bytes('c.bin', content())));
      final damaged = Uint8List.fromList(zip);
      final view = ByteData.sublistView(damaged);
      final link = (ZipDecoder()..decodeBytes(zip)).directory.fileHeaders[1];
      final data = link.localHeaderOffset +
          30 +
          view.getUint16(link.localHeaderOffset + 26, Endian.little) +
          view.getUint16(link.localHeaderOffset + 28, Endian.little);
      damaged.fillRange(data, data + 4, 0xff);
      var at = view.getUint32(zip.length - 6, Endian.little);
      at += 46 +
          view.getUint16(at + 28, Endian.little) +
          view.getUint16(at + 30, Endian.little) +
          view.getUint16(at + 32, Endian.little);
      view.setUint8(at + 5, 3);
      view.setUint32(at + 38, 0xa1ff << 16, Endian.little);
      final input = File(p.join(directory.path, 'link.zip'))
        ..writeAsBytesSync(damaged);
      final seen = <String>[];
      await extractFileToDisk(input.path, p.join(directory.path, 'out'),
          callback: (file) => seen.add(file.name));
      expect(File(p.join(directory.path, 'out', 'c.bin')).existsSync(), isTrue);
      expect(seen, ['a.bin', 'link', 'c.bin']);
    });

    test(
        'callback receives each entry once when duplicate name comes before '
        'unreadable zip link', () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = OutputMemoryStream();
      final encoder = ZipEncoder()..startEncode(output);
      encoder
        ..add(ArchiveFile.bytes('a.bin', content()))
        ..add(ArchiveFile.bytes('a.bin', content()))
        ..add(ArchiveFile.string('link', 'a.bin' * 600))
        ..add(ArchiveFile.bytes('c.bin', content()))
        ..endEncode();
      final zip = output.getBytes();
      final damaged = Uint8List.fromList(zip);
      final view = ByteData.sublistView(damaged);
      final link = (ZipDecoder()..decodeBytes(zip)).directory.fileHeaders[2];
      final data = link.localHeaderOffset +
          30 +
          view.getUint16(link.localHeaderOffset + 26, Endian.little) +
          view.getUint16(link.localHeaderOffset + 28, Endian.little);
      damaged.fillRange(data, data + 4, 0xff);
      var at = view.getUint32(zip.length - 6, Endian.little);
      for (var skipped = 0; skipped < 2; skipped++) {
        at += 46 +
            view.getUint16(at + 28, Endian.little) +
            view.getUint16(at + 30, Endian.little) +
            view.getUint16(at + 32, Endian.little);
      }
      view.setUint8(at + 5, 3);
      view.setUint32(at + 38, 0xa1ff << 16, Endian.little);
      final input = File(p.join(directory.path, 'duplicate.zip'))
        ..writeAsBytesSync(damaged);
      final seen = <String>[];
      await extractFileToDisk(input.path, p.join(directory.path, 'out'),
          callback: (file) => seen.add(file.name));
      expect(File(p.join(directory.path, 'out', 'c.bin')).existsSync(), isTrue);
      expect(seen, ['a.bin', 'link', 'c.bin']);
    });

    test('verify checks checksum of compressed tar container', () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final packed = GZipEncoder().encodeBytes(TarEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes('t.bin', content()))));
      packed[packed.length - 8] ^= 0xff;
      final input = File(p.join(directory.path, 'crc.tar.gz'))
        ..writeAsBytesSync(packed);

      final out = p.join(directory.path, 'out');
      await extractFileToDisk(input.path, out);
      expect(File(p.join(out, 't.bin')).readAsBytesSync(), content());

      await expectLater(
          extractFileToDisk(input.path, p.join(directory.path, 'checked'),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
    });

    test('callback error is rethrown, never reported as damaged archive',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final input = File(p.join(directory.path, 'a.tar'))
        ..writeAsBytesSync(TarEncoder()
            .encodeBytes(Archive()..add(ArchiveFile.bytes('a', content()))));
      const failure = FormatException('from the callback');
      await expectLater(
          extractFileToDisk(input.path, p.join(directory.path, 'out'),
              callback: (_) => throw failure),
          throwsA(same(failure)));
    });

    test('damaged central directory still extracts entries before damage',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final zip = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('one.bin', content()))
        ..add(ArchiveFile.bytes('two.bin', content())));
      final bytes = ByteData.sublistView(zip);
      var second = -1;
      for (var at = zip.length - 4, seen = 0; at >= 0; at--) {
        if (bytes.getUint32(at, Endian.little) == 0x02014b50 && ++seen == 1) {
          second = at;
          break;
        }
      }
      expect(second, greaterThan(0));
      zip[second] ^= 0xff;
      final input = File(p.join(directory.path, 'dir.zip'))
        ..writeAsBytesSync(zip);

      await expectLater(
          extractFileToDisk(input.path, p.join(directory.path, 'strict'),
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      final out = p.join(directory.path, 'out');
      await extractFileToDisk(input.path, out);
      expect(Directory(out).listSync().map((e) => p.basename(e.path)),
          ['one.bin']);
      expect(File(p.join(out, 'one.bin')).readAsBytesSync(), content());
    });
  });

  for (final format in ['tar', 'tar.gz', 'zip']) {
    test('extractFileToDisk $format callback runs after entry is written',
        () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final data = Uint8List.fromList(List.generate(70000, (i) => i * 7));
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', data))
        ..add(ArchiveFile.bytes('b.bin', data));
      final tar = TarEncoder().encodeBytes(archive);
      final input = File(p.join(directory.path, 'in.$format'))
        ..writeAsBytesSync(switch (format) {
          'tar' => tar,
          'tar.gz' => GZipEncoder().encodeBytes(tar),
          _ => ZipEncoder().encodeBytes(archive),
        });
      final out = p.join(directory.path, 'out');
      final seen = <String, List<int>?>{};
      await extractFileToDisk(input.path, out, callback: (file) {
        final written = File(p.join(out, file.name));
        seen[file.name] =
            written.existsSync() ? written.readAsBytesSync() : null;
      });
      expect(seen, {'a.bin': data, 'b.bin': data});
    });
  }

  group('extraction when file write fails', () {
    for (final method in ['sync', 'async']) {
      test('$method rethrows write error and leaves no file', () async {
        final directory =
            Directory.systemTemp.createTempSync('archive-extract-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final archive = Archive()
          ..add(ArchiveFile.file('a.bin', 10, _DiskFullContent()));
        final out = p.join(directory.path, 'out');
        Future<void> run() async => method == 'sync'
            ? extractArchiveToDiskSync(archive, out)
            : await extractArchiveToDisk(archive, out);
        await expectLater(run(), throwsA(isA<FileSystemException>()));
        expect(File(p.join(out, 'a.bin')).existsSync(), isFalse);
      });
    }

    test('extractFileToDisk rethrows write error and leaves no file', () async {
      final directory = Directory.systemTemp.createTempSync('archive-extract-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final input = File(p.join(directory.path, 'a.zip'))
        ..writeAsBytesSync(ZipEncoder().encodeBytes(
            Archive()..add(ArchiveFile.bytes('a.bin', Uint8List(100000)))));
      final out = p.join(directory.path, 'out');
      final target = p.join(out, 'a.bin');
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(extractFileToDisk(input.path, out),
            throwsA(isA<FileSystemException>()));
      }, _FullDiskIO(target));
      expect(File(target).existsSync(), isFalse);
    });
  });
}

class _DiskFullContent extends FileContent {
  static const _failure = FileSystemException('No space left on device');

  @override
  int get length => 10;

  @override
  InputStream getStream({bool decompress = true}) => throw _failure;

  @override
  void write(OutputStream output) => throw _failure;

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}
}

final class _FullDiskIO extends IOOverrides {
  final String target;

  _FullDiskIO(this.target);

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return p.equals(path, target) ? _FullDiskFile(real) : real;
  }
}

class _FullDiskFile implements File {
  final File _real;

  _FullDiskFile(this._real);

  @override
  String get path => _real.path;

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _real.createSync(recursive: recursive, exclusive: exclusive);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _FullDiskAccess(_real.openSync(mode: mode));

  @override
  void deleteSync({bool recursive = false}) =>
      _real.deleteSync(recursive: recursive);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FullDiskAccess implements RandomAccessFile {
  final RandomAccessFile _real;

  _FullDiskAccess(this._real);

  @override
  String get path => _real.path;

  @override
  int lengthSync() => _real.lengthSync();

  @override
  void setPositionSync(int position) => _real.setPositionSync(position);

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      throw FileSystemException('No space left on device', path);

  @override
  void closeSync() => _real.closeSync();

  @override
  Future<void> close() => _real.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

library archive_test;

import 'dart:io' as Io;

import 'package:archive/archive.dart';
import 'package:unittest/unittest.dart';

import '../bin/tar.dart' as tar_command;

part 'adler32_test.dart';
part 'commands_test.dart';
part 'crc32_test.dart';
part 'output_buffer_test.dart';
part 'tar_test.dart';
part 'zip_test.dart';

void compare_bytes(List<int> a, List<int> b) {
  expect(a.length, equals(b.length));
  int len = a.length;
  for (int i = 0; i < len; ++i) {
    expect(a[i], equals(b[i]), verbose: false);
  }
}

const String a_txt = """this is a test
of the
zip archive
format.
this is a test
of the
zip archive
format.
this is a test
of the
zip archive
format.
""";

void main() {
  defineOutputBufferTests();

  group('archive', () {
    List<int> a_bytes = a_txt.codeUnits;

    var b = new Io.File('res/cat.jpg');
    b.openSync();
    List<int> b_bytes = b.readAsBytesSync();

    test('GZipDecoder', () {
      var file = new Io.File('res/cat.jpg.gz');
      file.openSync();
      var bytes = file.readAsBytesSync();

      var z_bytes = new GZipDecoder().decode(bytes);
      compare_bytes(z_bytes, b_bytes);
    });

    test('ZipArchive', () {
      var file = new Io.File('res/test.zip');
      file.openSync();
      var bytes = file.readAsBytesSync();

      ZipArchive zip = new ZipArchive();
      Archive archive = zip.decode(bytes);
      expect(archive.numberOfFiles(), equals(2));

      for (int i = 0; i < archive.numberOfFiles(); ++i) {
        List<int> z_bytes = archive.fileData(i);
        if (archive.fileName(i) == 'a.txt') {
          compare_bytes(z_bytes, a_bytes);
        } else if (archive.fileName(i) == 'cat.jpg') {
          compare_bytes(z_bytes, b_bytes);
        } else {
          throw new TestFailure('Invalid file found');
        }
      }
    });

    test('TarArchive', () {
      var file = new Io.File('res/test.tar');
      file.openSync();
      List<int> bytes = file.readAsBytesSync();

      TarArchive tar = new TarArchive();

      Archive archive = tar.decode(bytes);
      expect(archive.numberOfFiles(), equals(2));

      for (int i = 0; i < archive.numberOfFiles(); ++i) {
        List<int> t_bytes = archive.fileData(i);
        String t_file = archive.fileName(i);

        if (t_file == 'a.txt') {
          compare_bytes(t_bytes, a_bytes);
        } else if (t_file == 'cat.jpg') {
          compare_bytes(t_bytes, b_bytes);
        } else {
          throw new TestFailure('Unexpected file found: $t_file');
        }
      }

      List<int> encoded = tar.encode(archive);

      // Test round-trip
      Archive archive2 = tar.decode(encoded);

      for (int i = 0; i < archive2.numberOfFiles(); ++i) {
        List<int> t_bytes = archive2.fileData(i);
        String t_file = archive2.fileName(i);

        if (t_file == 'a.txt') {
          compare_bytes(t_bytes, a_bytes);
        } else if (t_file == 'cat.jpg') {
          compare_bytes(t_bytes, b_bytes);
        } else {
          throw new TestFailure('Unexpected file found: $t_file');
        }
      }
    });
  });

  defineAdlerTests();

  defineCrc32Tests();

  defineTarTests();

  defineZipTests();

  defineCommandTests();
}

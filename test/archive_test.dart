import 'dart:io' as Io;
import 'package:unittest/unittest.dart';
import '../lib/archive.dart';

void compare_bytes(List<int> a, List<int> b) {
  expect(a.length, equals(b.length));
  int len = a.length;
  for (int i = 0; i < len; ++i) {
    expect(a[i], equals(b[i]), verbose: false);
  }
}


void main() {
  group('archive', () {
    /*var a = new Io.File('res/a.txt');
    a.openSync();
    List<int> a_bytes = a.readAsBytesSync();*/

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

    test('ZipDecoder', () {
      var file = new Io.File('res/test.zip');
      file.openSync();
      var bytes = file.readAsBytesSync();

      ZipDecoder zip = new ZipDecoder(bytes);
      expect(zip.numberOfFiles(), equals(2));

      for (int i = 0; i < zip.numberOfFiles(); ++i) {
        List<int> z_bytes = zip.fileData(i);
        if (zip.fileName(i) == 'a.txt') {
          //compare_bytes(zip.fileData(i), a_bytes);
        } else if (zip.fileName(i) == 'cat.jpg') {
          compare_bytes(zip.fileData(i), b_bytes);
        } else {
          throw new TestFailure('Invalid file found');
        }
      }
    });

    test('TarDecoder', () {
      var file = new Io.File('res/test.tar');
      file.openSync();
      var bytes = file.readAsBytesSync();

      TarDecoder tar = new TarDecoder(bytes);
      expect(tar.numberOfFiles(), equals(2));

      for (int i = 0; i < tar.numberOfFiles(); ++i) {
        List<int> t_bytes = tar.fileData(i);
        String t_file = tar.fileName(i);

        if (t_file == 'a.txt') {
          //compare_bytes(tar.fileData(i), a_bytes);
        } else if (t_file == 'cat.jpg') {
          compare_bytes(tar.fileData(i), b_bytes);
        } else {
          throw new TestFailure('Unexpected file found: $t_file');
        }
      }
    });
  });
}

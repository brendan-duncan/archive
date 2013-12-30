import 'dart:io' as Io;
import '../lib/dart_archive.dart';

void main() {
  print('test_archive');
  var file = new Io.File('res/test.zip');
  file.openSync();
  var bytes = file.readAsBytesSync();

  ZipDecoder zip = new ZipDecoder(bytes);

  var a = new Io.File('res/a.txt');
  a.openSync();
  var a_bytes = a.readAsBytesSync();
  var a_str = new String.fromCharCodes(a_bytes);

  var b = new Io.File('res/cat.jpg');
  b.openSync();
  var b_bytes = b.readAsBytesSync();

  for (int i = 0; i < zip.numberOfFiles(); ++i) {
    if (zip.fileName(i) == 'a.txt') {
      String z_str = new String.fromCharCodes(zip.fileData(i));
      if (z_str != a_str) {
        print('INCORRECT DECOMPRESSION A!');
      }
    } else if (zip.fileName(i) == 'cat.jpg') {
      List<int> z_bytes = zip.fileData(i);
      if (b_bytes.length != z_bytes.length) {
        print('[B] DECOMPRESSION FAILED: Sizes differ: ${b_bytes.length} ${z_bytes.length}');
        continue;
      }
      for (int i = 0; i < z_bytes.length; ++i) {
        if (z_bytes[i] != b_bytes[i]) {
          print('INCORRECT DECOMPRESSION B: $i');
        }
      }
    }
  }

  file = new Io.File('res/test.tar');
  file.openSync();
  bytes = file.readAsBytesSync();

  TarDecoder tar = new TarDecoder(bytes);
  for (int i = 0; i < tar.numberOfFiles(); ++i) {
    if (tar.fileName(i) == 'a.txt') {
      String z_str = new String.fromCharCodes(zip.fileData(i));
      if (z_str != a_str) {
        print('INCORRECT TAR FILE A!');
      }
    } else if (tar.fileName(i) == 'cat.jpg') {
      List<int> z_bytes = tar.fileData(i);
      if (b_bytes.length != z_bytes.length) {
        print('[B] TAR FAILED: Sizes differ: ${b_bytes.length} ${z_bytes.length}');
        continue;
      }
      for (int i = 0; i < z_bytes.length; ++i) {
        if (z_bytes[i] != b_bytes[i]) {
          print('INCORRECT TAR B: $i');
        }
      }
    }
  }
}

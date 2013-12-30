import 'dart:io' as Io;
import '../lib/dart_archive.dart';

void main() {
  var file = new Io.File('res/test.zip');
  file.openSync();
  var bytes = file.readAsBytesSync();

  ZipDecoder zip = new ZipDecoder(bytes);

  for (int i = 0; i < zip.numberOfFiles(); ++i) {
    print(zip.fileName(i));
    print(zip.fileSize(i));
    print(new String.fromCharCodes(zip.fileData(i)));
    print('=============================================');
  }
}

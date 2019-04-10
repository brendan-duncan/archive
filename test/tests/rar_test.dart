import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test('unrar', () {
    var rarDecoder = RarDecoder();
    var file = File(join(testDirPath, 'res/sample.rar'));
    var bytes = file.readAsBytesSync();
    
    var archive = rarDecoder.decodeBytes(bytes);
    print(archive.numberOfFiles());
  });
}

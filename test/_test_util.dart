import 'dart:io';

import 'package:test/test.dart';

//final testOutputPath = '${Directory.systemTemp.createTempSync().path}/out';
const testOutputPath = './_out';

const aTxt = '''this is a test
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
''';

void compareBytes(List<int> actual, List<int> expected) {
  expect(actual.length, equals(expected.length));
  final len = actual.length;
  for (var i = 0; i < len; ++i) {
    expect(actual[i], equals(expected[i]), reason: 'Wrong value for Byte at index $i');
  }
}

void listDir(List<File> files, Directory dir) {
  var fileOrDirs = dir.listSync(recursive: true);
  for (final f in fileOrDirs) {
    if (f is File) {
      // Ignore paxHeader files, which 7zip write out since it doesn't properly
      // handle POSIX tar files.
      if (f.path.contains('PaxHeader')) {
        continue;
      }
      files.add(f);
    }
  }
}

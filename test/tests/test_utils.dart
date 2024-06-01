library archive.test.test_utils;

import 'dart:io' as io;
import 'dart:mirrors';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String testDirPath = p.dirname(p.fromUri(currentMirrorSystem()
    .findLibrary(const Symbol('archive.test.test_utils'))
    .uri));

void compareBytes(List<int> actual, List<int> expected) {
  expect(actual.length, equals(expected.length));
  final len = actual.length;
  for (var i = 0; i < len; ++i) {
    expect(actual[i], equals(expected[i]),
        reason: 'Wrong value for Byte at index $i');
  }
}

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

void listDir(List<io.File> files, io.Directory dir) {
  var fileOrDirs = dir.listSync(recursive: true);
  for (var f in fileOrDirs) {
    if (f is io.File) {
      // Ignore paxHeader files, which 7zip write out since it doesn't properly
      // handle POSIX tar files.
      if (f.path.contains('PaxHeader')) {
        continue;
      }
      files.add(f);
    }
  }
}

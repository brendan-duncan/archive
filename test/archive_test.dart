library archive_test;

import 'dart:io' as Io;

import 'package:archive/archive.dart';
import 'package:unittest/unittest.dart';

import '../bin/tar.dart' as tar_command;

part 'adler32_test.dart';
part 'commands_test.dart';
part 'crc32_test.dart';
part 'deflate_test.dart';
part 'gzip_test.dart';
part 'output_buffer_test.dart';
part 'tar_test.dart';
part 'zip_test.dart';
part 'zlib_test.dart';

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

  defineAdlerTests();

  defineCrc32Tests();

  defineDeflateTests();

  defineZlibTests();

  defineGZipTests();

  defineTarTests();

  defineZipTests();

  defineCommandTests();
}

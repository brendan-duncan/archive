import 'dart:io' as io;

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:archive/src/tar/tar_command.dart' as tar_command;

import 'test_utils.dart';

void main() {
  test('bin/tar.dart list', () {
    // Test that 'tar --list' does not throw.
    tar_command.listFiles(p.join(testDirPath, 'res/test2.tar.gz'));
  });

  test('tar extract', () {
    io.Directory dir = io.Directory.systemTemp.createTempSync('foo');

    try {
      //print(dir.path);

      String inputPath = p.join(testDirPath, 'res/test2.tar.gz');

      {
        io.Directory temp_dir =
            io.Directory.systemTemp.createTempSync('dart_archive');
        String tar_path =
            '${temp_dir.path}${io.Platform.pathSeparator}temp.tar';
        InputFileStream input = InputFileStream(inputPath);
        OutputFileStream output = OutputFileStream(tar_path);
        GZipDecoder().decodeStream(input, output);
        input.close();
        output.close();

        List<int> a_bytes = io.File(tar_path).readAsBytesSync();
        List<int> b_bytes =
            io.File(p.join(testDirPath, 'res/test2.tar')).readAsBytesSync();

        expect(a_bytes.length, equals(b_bytes.length));
        bool same = true;
        for (int i = 0; same && i < a_bytes.length; ++i) {
          same = a_bytes[i] == b_bytes[i];
        }
        expect(same, equals(true));

        temp_dir.deleteSync(recursive: true);
      }

      tar_command.extractFiles(
          p.join(testDirPath, 'res/test2.tar.gz'), dir.path);
      expect(dir.listSync(recursive: true).length, 4);
    } finally {
      //dir.deleteSync(recursive: true);
    }
  });

  test('tar create', () {
    io.Directory dir = io.Directory.systemTemp.createTempSync('foo');
    io.File file =
        io.File('${dir.path}${io.Platform.pathSeparator}foo.txt');
    file.writeAsStringSync('foo bar');

    try {
      // Test that 'tar --create' does not throw.
      tar_command.createTarFile(dir.path);
    } finally {
      dir.delete(recursive: true);
    }
  });
}

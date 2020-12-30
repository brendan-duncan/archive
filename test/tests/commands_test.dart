import 'dart:io';

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
    final dir = Directory.systemTemp.createTempSync('foo');

    try {
      //print(dir.path);

      final inputPath = p.join(testDirPath, 'res/test2.tar.gz');

      {
        final temp_dir = Directory.systemTemp.createTempSync('dart_archive');
        final tar_path = '${temp_dir.path}${Platform.pathSeparator}temp.tar';
        final input = InputFileStream(inputPath);
        final output = OutputFileStream(tar_path);
        GZipDecoder().decodeStream(input, output);
        input.close();
        output.close();

        final a_bytes = File(tar_path).readAsBytesSync();
        final b_bytes =
            File(p.join(testDirPath, 'res/test2.tar')).readAsBytesSync();

        expect(a_bytes.length, equals(b_bytes.length));
        var same = true;
        for (var i = 0; same && i < a_bytes.length; ++i) {
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
    final dir = Directory.systemTemp.createTempSync('foo');
    final file = File('${dir.path}${Platform.pathSeparator}foo.txt');
    file.writeAsStringSync('foo bar');

    try {
      // Test that 'tar --create' does not throw.
      tar_command.createTarFile(dir.path);
    } finally {
      dir.delete(recursive: true);
    }
  });
}

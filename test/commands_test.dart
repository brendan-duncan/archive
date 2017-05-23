part of archive_test;

void defineCommandTests() {
  File script = new File(Platform.script.toFilePath());
  String path = script.parent.path;

  group('commands', () {
    test('bin/tar.dart list', () {
      // Test that 'tar --list' does not throw.
      tar_command.listFiles(path + '/res/test.tar.gz');
    });

    test('tar extract', () {
      Directory dir = Directory.systemTemp.createTempSync('foo');

      try {
        tar_command.extractFiles(path + '/res/test.tar.gz', dir.path);
        expect(dir.listSync().length, 9);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('tar create', () {
      Directory dir = Directory.systemTemp.createTempSync('foo');
      File file = new File('${dir.path}${Platform.pathSeparator}foo.txt');
      file.writeAsStringSync('foo bar');

      try {
        // Test that 'tar --create' does not throw.
        /*File tarFile =*/ tar_command.createTarFile(dir.path);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

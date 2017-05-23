part of archive_test;

void defineCommandTests() {
  io.File script = new io.File(io.Platform.script.toFilePath());
  String path = script.parent.path;

  group('commands', () {
    test('bin/tar.dart list', () {
      // Test that 'tar --list' does not throw.
      tar_command.listFiles(path + '/res/test.tar.gz');
    });

    test('tar extract', () {
      io.Directory dir = io.Directory.systemTemp.createTempSync('foo');

      try {
        tar_command.extractFiles(path + '/res/test.tar.gz', dir.path);
        expect(dir.listSync().length, 9);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('tar create', () {
      io.Directory dir = io.Directory.systemTemp.createTempSync('foo');
      io.File file = new io.File('${dir.path}${io.Platform.pathSeparator}foo.txt');
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

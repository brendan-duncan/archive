
part of archive_test;

void defineCommandTests() {
  group('commands', () {
    test('bin/tar.dart list', () {
      // Test that 'tar --list' does not throw.
      tar_command.listFiles('res/test.tar.gz');
    });

    test('tar extract', () {
      Io.Directory dir = Io.Directory.systemTemp.createTempSync('foo');

      try {
        tar_command.extractFiles('res/test.tar.gz', dir.path);
        expect(dir.listSync().length, 9);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('tar create', () {
      Io.Directory dir = Io.Directory.systemTemp.createTempSync('foo');
      Io.File file = new Io.File('${dir.path}${Io.Platform.pathSeparator}foo.txt');
      file.writeAsStringSync('foo bar');

      try {
        // Test that 'tar --create' does not throw.
        Io.File tarFile = tar_command.createTarFile(dir.path);
        expect(tarFile.lengthSync(), greaterThan(100));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

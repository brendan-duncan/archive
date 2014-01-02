
part of archive_test;

void defineCommandTests() {
  group('commands', () {
    test('bin/tar.dart list', () {
      // Test that 'tar --list' does not throw.
      tar_command.listFiles('res/test.tar.gz');
    });
  });
}

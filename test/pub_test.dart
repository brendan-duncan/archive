part of archive_test;

void GetFiles(List files, Directory dir) {
  List contents = dir.listSync();
  for (var fileOrDir in contents) {
    if (fileOrDir is File) {
      files.add(fileOrDir as File);
    } else if (fileOrDir is Directory) {
      GetFiles(files, fileOrDir as Directory);
    }
  }
}

void definePubTests() {
  group('pub archives', () {
    HttpClient client;

    setUpAll(() {
      client = new HttpClient();
    });

    tearDownAll(() {
      client.close(force: true);
    });

    test('logfmt 0.4.0', () async {
      final HttpClientRequest rq = await client.getUrl(Uri.parse(
          'https://storage.googleapis.com/pub-packages/packages/logfmt-0.4.0.tar.gz'));
      final HttpClientResponse rs = await rq.close();
      final List<int> data = (await rs.toList())
          .fold([], (List<int> a, List<int> b) => a..addAll(b));
      expect(data.length, 10240);

      final Archive archive =
          new TarDecoder().decodeBytes(new GZipDecoder().decodeBytes(data));
      expect(archive.toList(), isNotEmpty);
    });
  });
}

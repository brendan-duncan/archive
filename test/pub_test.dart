part of archive_test;

void definePubTests() {
  group('pub archives', () {
    io.HttpClient client;

    setUpAll(() {
      client = new io.HttpClient();
    });

    tearDownAll(() {
      client.close(force: true);
    });

    test('logfmt 0.4.0', () async {
      final io.HttpClientRequest rq = await client.getUrl(Uri.parse(
          'https://storage.googleapis.com/pub-packages/packages/logfmt-0.4.0.tar.gz'));
      final io.HttpClientResponse rs = await rq.close();
      final List<int> data = (await rs.toList())
          .fold([], (List<int> a, List<int> b) => a..addAll(b));
      expect(data.length, 10240);

      final Archive archive =
          new TarDecoder().decodeBytes(new GZipDecoder().decodeBytes(data));
      expect(archive.toList().length, 21);
    });
  });
}

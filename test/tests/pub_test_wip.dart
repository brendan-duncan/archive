import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void extract7z(List<String> urls) {
  final script = File(Platform.script.toFilePath());
  final path = script.parent.path;

  for (final url in urls) {
    final filename = url.split('/').last;
    final inputPath = '$path\\out\\$filename';

    final outputPath = path + '\\out\\' + filename + '.7z';
    print('$inputPath : $outputPath');

    final outDir = Directory(outputPath);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    print('EXTRACTING $inputPath');
    Process.runSync('7z', ['x', '-o${outputPath}', '$inputPath']);

    final tar_filename = filename.substring(0, filename.lastIndexOf('.'));
    var tar_path = '$outputPath\\$tar_filename';
    if (!File(tar_path).existsSync()) {
      tar_path = '$outputPath\\intermediate.tar';
    }
    print('TAR $tar_path');

    Process.runSync('7z', ['x', '-y', '-o${outputPath}', '$tar_path']);

    File(tar_path).deleteSync();
  }
}

Future<void> downloadUrls(HttpClient? client, List<String> urls) async {
  final script = File(Platform.script.toFilePath());
  final path = script.parent.path;

  final downloads = <dynamic>[];
  for (final url in urls) {
    print(url);

    final filename = url.split('/').last;

    var download = HttpClient()
        .getUrl(Uri.parse(url))
        .then(((HttpClientRequest request) => request.close()))
        .then<dynamic>(((HttpClientResponse response) => response
            .cast<List<int>>()
            .pipe(File(path + '/out/' + filename).openWrite())));

    downloads.add(download);
  }

  for (var download in downloads) {
    await download;
  }
}

void extractDart(List<String> urls) {
  final script = File(Platform.script.toFilePath());
  final path = script.parent.path;

  for (final url in urls) {
    final filename = url.split('/').last;
    final inputPath = '$path\\out\\$filename';

    final outputPath = path + '\\out\\' + filename + '.out';
    print('$inputPath : $outputPath');

    print('EXTRACTING $inputPath');

    final fp = File(path + '/out/' + filename);
    final data = fp.readAsBytesSync();

    final tarArchive = TarDecoder();
    tarArchive.decodeBytes(GZipDecoder().decodeBytes(data));

    print('EXTRACTING $filename');

    final outDir = Directory(outputPath);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    for (final file in tarArchive.files) {
      if (!file.isFile) {
        continue;
      }
      final filename = file.filename;
      try {
        final f = File('${outputPath}${Platform.pathSeparator}${filename}');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(file.content as List<int>);
      } catch (e) {
        print(e);
      }
    }
  }
}

void compareDirs(List<String> urls) {
  final script = File(Platform.script.toFilePath());
  final path = script.parent.path;

  for (final url in urls) {
    final filename = url.split('/').last;
    final outPath7z = '$path\\out\\${filename}.7z';
    final outPathDart = '$path\\out\\${filename}.out';
    print('$outPathDart : $outPath7z');

    final files7z = <File>[];
    ListDir(files7z, Directory(outPath7z));
    final filesDart = <File>[];
    ListDir(filesDart, Directory(outPathDart));

    expect(filesDart.length, files7z.length);
    //print("#${filesDart.length} : ${files7z.length}");

    for (var i = 0; i < filesDart.length; ++i) {
      final fd = filesDart[i];
      final f7z = files7z[i];

      List bytes_dart = fd.readAsBytesSync();
      List bytes_7z = f7z.readAsBytesSync();

      expect(bytes_dart.length, bytes_7z.length);

      for (var j = 0; j < bytes_dart.length; ++j) {
        expect(bytes_dart[j], bytes_7z[j]);
      }
    }
  }
}

void definePubTests() {
  group('pub archives', () {
    HttpClient? client;

    setUpAll(() {
      client = HttpClient();
    });

    tearDownAll(() {
      client!.close(force: true);
    });

    test('PUB ARCHIVES', () async {
      final script = File(Platform.script.toFilePath());
      final path = script.parent.path;
      final fp = File(path + '/res/tarurls.txt');
      final urls = fp.readAsLinesSync();

      await downloadUrls(client, urls);
      extractDart(urls);
      // TODO need a generic system level tar exe to work with the
      // travis CI system.
      //extract7z(urls);
      //compareDirs(urls);
    });
  });
}

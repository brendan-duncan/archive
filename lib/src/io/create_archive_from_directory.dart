import 'dart:io';
import 'package:path/path.dart' as path;
import '../archive.dart';
import '../archive_file.dart';
import 'input_file_stream.dart';

Archive createArchiveFromDirectory(Directory dir,
    {bool includeDirName = true}) {
  final archive = Archive();

  final dirName = path.basename(dir.path);
  List files = dir.listSync(recursive: true);
  for (var file in files) {
    if (file is! File) {
      continue;
    }

    final f = file;
    var filename = path.relative(f.path, from: dir.path);
    filename = includeDirName ? (dirName + '/' + filename) : filename;

    final fileStream = InputFileStream(f.path);

    final af = ArchiveFile.stream(filename, f.lengthSync(), fileStream);
    af.lastModTime = f.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    af.mode = f.statSync().mode;

    archive.addFile(af);
  }

  return archive;
}

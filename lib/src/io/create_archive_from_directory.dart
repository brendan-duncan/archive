import 'dart:io';
import 'package:path/path.dart' as path;
import '../archive.dart';
import '../archive_file.dart';
import 'input_file_stream.dart';

Archive createArchiveFromDirectory(Directory dir,
    {bool includeDirName = true}) {
  final archive = Archive();

  final dir_name = path.basename(dir.path);
  List files = dir.listSync(recursive: true);
  for (var file in files) {
    if (file is! File) {
      continue;
    }

    final f = file;
    var filename = path.relative(f.path, from: dir.path);
    filename = includeDirName ? (dir_name + '/' + filename) : filename;

    final file_stream = InputFileStream.file(f);

    final af = ArchiveFile.stream(filename, f.lengthSync(), file_stream);
    af.lastModTime = f.lastModifiedSync().millisecondsSinceEpoch;
    af.mode = f.statSync().mode;

    archive.addFile(af);
  }

  return archive;
}

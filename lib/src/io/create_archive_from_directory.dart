import 'dart:io';
import 'package:path/path.dart' as path;
import '../archive.dart';
import '../archive_file.dart';
import 'input_file_stream.dart';

Archive createArchiveFromDirectory(Directory dir) {
  Archive archive = new Archive();

  List files = dir.listSync(recursive: true);
  for (var file in files) {
    if (file is! File) {
      continue;
    }

    File f = file as File;
    String filename = path.relative(f.path, from: dir.path);

    InputFileStream file_stream = new InputFileStream.file(file);

    ArchiveFile af = new ArchiveFile.stream(
        filename == null ? file.path : filename,
        file.lengthSync(), file_stream);
    af.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch;
    af.mode = file.statSync().mode;

    archive.addFile(af);
  }

  return archive;
}

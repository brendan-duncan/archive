import 'dart:io';
import 'package:path/path.dart' as path;
import '../archive.dart';
import '../archive_file.dart';
import 'input_file_stream.dart';

Archive createArchiveFromDirectory(Directory dir, {bool includeDirName = true}) {
  Archive archive = new Archive();

  String dir_name = path.basename(dir.path);
  List files = dir.listSync(recursive: true);
  for (var file in files) {
    if (file is! File) {
      continue;
    }

    File f = file as File;
    String filename = path.relative(f.path, from: dir.path);
    filename = includeDirName ? (dir_name + "/" + filename) : filename;

    InputFileStream file_stream = new InputFileStream.file(file);

    ArchiveFile af = new ArchiveFile.stream(filename, file.lengthSync(),
                                            file_stream);
    af.lastModTime = file.lastModifiedSync().millisecondsSinceEpoch;
    af.mode = file.statSync().mode;

    archive.addFile(af);
  }

  return archive;
}

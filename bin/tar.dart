
library archive.tar;

import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:archive/archive.dart';

// tar --list <file>
// tar --extract <file> <dest>
// tar --create <source>

void main(List arguments) {
  ArgParser args = new ArgParser();
  args.addFlag('list', abbr: 't', help: '<file>', negatable: false);
  args.addFlag('extract', abbr: 'x', help: '<file> <dest>', negatable: false);
  args.addFlag('create', abbr: 'c', help: '<directory>', negatable: false);

  ArgResults results = args.parse(arguments);
  List<String> files = results.rest;

  if (results['list']) {
    if (files.isEmpty) fail('expected the archive to act on');

    listFiles(files.first);
  } else if (results['create']) {
    if (files.isEmpty) fail('expected the directory to tar');

    createTarFile(files.first);
  } else if (results['extract']) {
    if (files.isEmpty) fail('expected the archive to extract');
    if (files.length < 2) fail('expected the directory to extract to');

    extractFiles(files.first, files[1]);
  } else {
    print('usage: tar [--list|--extract|--create] <file> [<dest>|<source>]');
    print('');
    fail(args.usage);
  }
}

/**
 * Print the entries in the given tar file.
 */
void listFiles(String path) {
  io.File file = new io.File(path);
  if (!file.existsSync()) fail('${path} does not exist');

  List<int> data = file.readAsBytesSync();
  if (path.endsWith('tar.gz') || path.endsWith('tgz')) {
    data = new GZipDecoder().decodeBytes(data);
  } else if (path.endsWith('tar.bz2') || path.endsWith('tbz')) {
    data = new BZip2Decoder().decodeBytes(data);
  }

  TarDecoder tarArchive = new TarDecoder();
  tarArchive.decodeBytes(data);

  print('${tarArchive.files.length} file(s)');
  tarArchive.files.forEach((f) => print('  ${f}'));
}

/**
 * Extract the entries in the given tar file to a directory.
 */
io.Directory extractFiles(String inputPath, String outputPath) {
  io.File inputFile = new io.File(inputPath);
  if (!inputFile.existsSync()) fail('${inputPath} does not exist');

  io.Directory outDir = new io.Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  List<int> data = inputFile.readAsBytesSync();
  if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
    data = new GZipDecoder().decodeBytes(data);
  } else if (inputPath.endsWith('tar.bz2') || inputPath.endsWith('tbz')) {
    data = new BZip2Decoder().decodeBytes(data);
  }

  TarDecoder tarArchive = new TarDecoder();
  tarArchive.decodeBytes(data);

  print('extracting to ${outDir.path}${io.Platform.pathSeparator}...');

  for (TarFile file in tarArchive.files) {
    io.File f = new io.File(
        '${outputPath}${io.Platform.pathSeparator}${file.filename}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(file.content);
    print('  extracted ${file.filename}');
  };

  return outDir;
}

io.File createTarFile(String dirPath) {
  io.Directory dir = new io.Directory(dirPath);
  if (!dir.existsSync()) fail('${dirPath} does not exist');

  io.File outFile = new io.File('${dirPath}.tar.gz');
  print('creating ${outFile.path}...');

  Archive archive = new Archive();

  for (io.FileSystemEntity entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is io.File) {
      String name = entity.path;
      if (name.startsWith(dir.path)) {
        name = name.substring(dir.path.length);
      }
      if (name.startsWith(io.Platform.pathSeparator)) {
        name = name.substring(io.Platform.pathSeparator.length);
      }
      ArchiveFile file = new ArchiveFile(name, entity.lengthSync(),
                                         entity.readAsBytesSync());
      file.lastModTime = entity.lastModifiedSync().millisecondsSinceEpoch;
      file.mode = entity.statSync().mode;
      print('  added ${name}');
      archive.addFile(file);
    }
  }

  List<int> data = new TarEncoder().encode(archive);
  data = new GZipEncoder().encode(data);

  outFile.writeAsBytesSync(data);

  return outFile;
}

void fail(String message) {
  print(message);
  io.exit(1);
}

import 'dart:io';
import 'package:archive/archive_io.dart';

/// Print the entries in the given tar file.
void listFiles(String path) {
  final file = File(path);
  if (!file.existsSync()) fail('${path} does not exist');

  List<int> data = file.readAsBytesSync();
  if (path.endsWith('tar.gz') || path.endsWith('tgz')) {
    data = GZipDecoder().decodeBytes(data);
  } else if (path.endsWith('tar.bz2') || path.endsWith('tbz')) {
    data = BZip2Decoder().decodeBytes(data);
  }

  final tarArchive = TarDecoder();
  // Tell the decoder not to store the actual file data since we don't need
  // it.
  tarArchive.decodeBytes(data, storeData: false);

  print('${tarArchive.files.length} file(s)');
  tarArchive.files.forEach((f) => print('  ${f}'));
}

/// Extract the entries in the given tar file to a directory.
Directory extractFiles(String inputPath, String outputPath) {
  Directory? temp_dir;
  var tar_path = inputPath;

  if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
    temp_dir = Directory.systemTemp.createTempSync('dart_archive');
    tar_path = '${temp_dir.path}${Platform.pathSeparator}temp.tar';
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(tar_path);
    GZipDecoder().decodeStream(input, output);
    input.close();
    output.close();
  }

  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  final input = InputFileStream(tar_path);
  final tarArchive = TarDecoder()..decodeBuffer(input);

  for (final file in tarArchive.files) {
    if (!file.isFile) {
      continue;
    }
    final f = File('${outputPath}${Platform.pathSeparator}${file.filename}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(file.contentBytes);
    print('  extracted ${file.filename}');
  }

  input.close();

  if (temp_dir != null) {
    temp_dir.delete(recursive: true);
  }

  /*File inputFile = File(inputPath);
  if (!inputFile.existsSync()) fail('${inputPath} does not exist');

  Directory outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  List<int> data = inputFile.readAsBytesSync();
  if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
    data = GZipDecoder().decodeBytes(data);
  } else if (inputPath.endsWith('tar.bz2') || inputPath.endsWith('tbz')) {
    data = BZip2Decoder().decodeBytes(data);
  }

  TarDecoder tarArchive = TarDecoder();
  tarArchive.decodeBytes(data);*

  print('extracting to ${outDir.path}${Platform.pathSeparator}...');

  for (TarFile file in tarArchive.files) {
    if (!file.isFile) {
      continue;
    }
    File f = File(
        '${outputPath}${Platform.pathSeparator}${file.filename}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(file.content);
    print('  extracted ${file.filename}');
  };*/

  return outDir;
}

void createTarFile(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) fail('${dirPath} does not exist');

  // Encode a directory from disk to disk, no memory
  final encoder = TarFileEncoder();
  encoder.tarDirectory(dir, compression: TarFileEncoder.GZIP);
}

void fail(String message) {
  print(message);
  exit(1);
}

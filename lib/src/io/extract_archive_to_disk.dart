import 'dart:io';
import 'input_file_stream.dart';
import 'output_file_stream.dart';
import '../archive.dart';
import '../gzip_decoder.dart';
import '../bzip2_decoder.dart';
import '../tar_decoder.dart';
import '../zip_decoder.dart';
import '../util/input_stream.dart';

void extractArchiveToDisk(Archive archive, String outputPath) {
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    final f = File('${outputPath}${Platform.pathSeparator}${file.name}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(file.content as List<int>);
  }
}

void extractFileToDisk(String inputPath, String outputPath,
    {String? password}) {
  Directory? tempDir;
  var archivePath = inputPath;

  if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = '${tempDir.path}${Platform.pathSeparator}temp.tar';
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath);
    GZipDecoder().decodeStream(input, output);
    input.close();
    output.close();
  } else if (inputPath.endsWith('tar.bz2') || inputPath.endsWith('tbz')) {
    tempDir = Directory.systemTemp.createTempSync('dart_archive');
    archivePath = '${tempDir.path}${Platform.pathSeparator}temp.tar';
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(archivePath);
    BZip2Decoder().decodeBuffer(input, output: output);
    input.close();
    output.close();
  }

  Archive archive;
  if (archivePath.endsWith('tar')) {
    final input = InputFileStream(archivePath);
    archive = TarDecoder().decodeBuffer(input);
  } else if (archivePath.endsWith('zip')) {
    final input = InputStream(File(archivePath).readAsBytesSync());
    archive = ZipDecoder().decodeBuffer(input, password: password);
  } else {
    throw ArgumentError.value(inputPath, 'inputPath',
        'Must end tar.gz, tgz, tar.bz2, tbz, tar or zip.');
  }

  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    final f = File('${outputPath}${Platform.pathSeparator}${file.name}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(file.content as List<int>);
  }

  if (tempDir != null) {
    tempDir.delete(recursive: true);
  }
}

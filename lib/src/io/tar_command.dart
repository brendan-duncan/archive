// ignore_for_file: avoid_print
import 'dart:io';

import '../../archive_io.dart';
import '_entry_writer.dart';

/// Print the entries in the given tar file.
void listTarFiles(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail('$path does not exist');
  }

  final input = InputFileStream(path);
  try {
    final tar = _tarStream(path, input);
    final tarArchive = TarDecoder();
    // Tell the decoder not to store the actual file data since we don't need
    // it.
    tarArchive.decodeStream(tar, storeData: false);

    print('${tarArchive.files.length} file(s)');
    for (final f in tarArchive.files) {
      print('  $f');
    }
  } finally {
    input.closeSync();
  }
}

/// Extract the entries in the given tar file to a directory.
///
/// Entries are kept inside [outputPath] as [extractArchiveToDiskSync]
/// describes.
Directory extractTarFiles(String inputPath, String outputPath) {
  final input = InputFileStream(inputPath);
  try {
    final writer = EntryWriter(outputPath);
    TarDecoder().decodeStream(_tarStream(inputPath, input), keepEntries: false,
        callback: (entry) {
      final path = writer.write(entry);
      if (path != null && entry.isFile && !entry.isSymbolicLink) {
        print('  extracted $path');
      }
    });
    writer.finish();
  } finally {
    input.closeSync();
  }
  return Directory(outputPath);
}

// The tar in [input], decompressed as it is read if [path] says it is
// compressed.
InputStream _tarStream(String path, InputStream input) =>
    tarStreamFor(getInputExtension(path), input) ?? input;

Future<void> createTarFile(String dirPath) async {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    _fail('$dirPath does not exist');
  }

  // Encode a directory from disk to disk, no memory
  final encoder = TarFileEncoder();
  await encoder.tarDirectory(dir, compression: TarFileEncoder.gzip);
}

void _fail(String message) {
  print(message);
  exit(1);
}

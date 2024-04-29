import 'dart:io';
import 'package:archive/archive_io.dart';

Future<void> main() async {
  // Read the Zip file from disk.
  final input = InputFileStream('test.zip');

  // Decode the Zip file
  final archive = ZipDecoder().decodeStream(input);

  // Extract the contents of the Zip archive to disk.
  for (final file in archive) {
    final filename = file.name;
    if (file.isFile) {
      final output = OutputFileStream('out/$filename');
      output.writeStream(file.getContent()!);
      await file.close();
    } else {
      await Directory('out/$filename').create(recursive: true);
    }
  }

  // Encode the archive as a BZip2 compressed Tar file.
  final tarData = TarEncoder().encodeBytes(archive);
  final tarBz2 = BZip2Encoder().encodeBytes(tarData);

  // Write the compressed tar file to disk.
  final fp = File('test.tbz');
  fp.writeAsBytesSync(tarBz2);

  // Zip a directory to out.zip using the zipDirectory convenience method
  var encoder = ZipFileEncoder();
  await encoder.zipDirectory(Directory('out'), filename: 'out.zip');

  // Manually create a zip of a directory and individual files.
  encoder.create('out2.zip');
  await encoder.addDirectory(Directory('out'));
  await encoder.addFile(File('test.zip'));
  encoder.closeSync();
}

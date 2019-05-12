import 'dart:io';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';

void main() {
  // Read the Zip file from disk.
  List<int> bytes = File('test.zip').readAsBytesSync();

  // Decode the Zip file
  Archive archive = ZipDecoder().decodeBytes(bytes);

  // Extract the contents of the Zip archive to disk.
  for (ArchiveFile file in archive) {
    String filename = file.name;
    if (file.isFile) {
      List<int> data = file.content;
      File('out/' + filename)
        ..createSync(recursive: true)
        ..writeAsBytesSync(data);
    } else {
      Directory('out/' + filename)
        ..create(recursive: true);
    }
  }

  // Encode the archive as a BZip2 compressed Tar file.
  List<int> tar_data = TarEncoder().encode(archive);
  List<int> tar_bz2 = BZip2Encoder().encode(tar_data);

  // Write the compressed tar file to disk.
  File fp = File('test.tbz');
  fp.writeAsBytesSync(tar_bz2);

  // Zip a directory to out.zip using the zipDirectory convenience method
  var encoder = ZipFileEncoder();
  encoder.zipDirectory(Directory('out'), filename: 'out.zip');

  // Manually create a zip of a directory and individual files.
  encoder.create('out2.zip');
  encoder.addDirectory(Directory('out'));
  encoder.addFile(File('test.zip'));
  encoder.close();
}

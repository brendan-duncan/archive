import 'tar/tar_file.dart';
import 'util/input_stream.dart';
import 'archive.dart';
import 'archive_file.dart';

/// Decode a tar formatted buffer into an [Archive] object.
class TarDecoder {
  List<TarFile> files = [];

  Archive decodeBytes(List<int> data,
      {bool verify = false, bool storeData = true}) {
    return decodeBuffer(InputStream(data),
        verify: verify, storeData: storeData);
  }

  Archive decodeBuffer(InputStreamBase input,
      {bool verify = false, bool storeData = true}) {
    final archive = Archive();
    files.clear();

    String? nextName;

    // TarFile paxHeader = null;
    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      final end_check = input.peekBytes(2);
      if (end_check.length < 2 || (end_check[0] == 0 && end_check[1] == 0)) {
        break;
      }

      final tf = TarFile.read(input, storeData: storeData);
      // GNU tar puts filenames in files when they exceed tar's native length.
      if (tf.filename == '././@LongLink') {
        nextName = tf.rawContent!.readString();
        continue;
      }

      // In POSIX formatted tar files, a separate 'PAX' file contains extended
      // metadata for files. These are identified by having a type flag 'X'.
      // TODO: parse these metadata values.
      if (tf.typeFlag == TarFile.TYPE_G_EX_HEADER ||
          tf.typeFlag == TarFile.TYPE_G_EX_HEADER2) {
        // TODO handle PAX global header.
      }
      if (tf.typeFlag == TarFile.TYPE_EX_HEADER ||
          tf.typeFlag == TarFile.TYPE_EX_HEADER2) {
        //paxHeader = tf;
      } else {
        files.add(tf);

        final file =
            ArchiveFile(nextName ?? tf.filename, tf.fileSize, tf.rawContent);

        file.mode = tf.mode;
        file.ownerId = tf.ownerId;
        file.groupId = tf.groupId;
        file.lastModTime = tf.lastModTime;
        file.isFile = tf.isFile;
        file.isSymbolicLink = tf.typeFlag == TarFile.TYPE_SYMBOLIC_LINK;
        file.nameOfLinkedFile = tf.nameOfLinkedFile;

        archive.addFile(file);

        nextName = null;
      }
    }

    return archive;
  }
}

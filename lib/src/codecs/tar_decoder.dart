import 'dart:convert';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'tar/tar_file.dart';

final paxRecordRegexp = RegExp(r"(\d+) (\w+)=(.*)");

/// Decode a tar formatted buffer into an [Archive] object.
class TarDecoder {
  final Encoding filenameEncoding;
  List<TarFile> files = [];

  TarDecoder({this.filenameEncoding = const Utf8Codec()});

  Archive decodeBytes(List<int> data,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    return decodeStream(InputMemoryStream(data),
        verify: verify, storeData: storeData, callback: callback);
  }

  Archive decodeStream(InputStream input,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    final archive = Archive();
    files.clear();

    String? nextName;
    String? nextLinkName;

    // TarFile paxHeader = null;
    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      final endCheck = input.peekBytes(2).toUint8List();
      if (endCheck.length < 2 || (endCheck[0] == 0 && endCheck[1] == 0)) {
        break;
      }

      final tf =
          TarFile.read(input, storeData: storeData, encoding: filenameEncoding);
      // GNU tar puts filenames in files when they exceed tar's native length.
      if (tf.filename == '././@LongLink') {
        nextName = tf.rawContent!.readString();
        continue;
      }

      // In POSIX formatted tar files, a separate 'PAX' file contains extended
      // metadata for files. These are identified by having a type flag 'X'.
      // TODO: parse these metadata values.
      if (tf.typeFlag == TarFile.gExHeader ||
          tf.typeFlag == TarFile.gExHeader2) {
        // TODO handle PAX global header.
        continue;
      }
      if (tf.typeFlag == TarFile.exHeader || tf.typeFlag == TarFile.exHeader2) {
        utf8
            .decode(tf.rawContent!.toUint8List())
            .split('\n')
            .where((s) => paxRecordRegexp.hasMatch(s))
            .forEach((record) {
          final match = paxRecordRegexp.firstMatch(record)!;
          final keyword = match.group(2);
          final value = match.group(3)!;
          switch (keyword) {
            case 'path':
              nextName = value;
              break;
            case 'linkpath':
              nextLinkName = value;
              break;
            default:
            // TODO: support other pax headers.
          }
        });
        continue;
      }

      // Fix file attributes.
      if (nextName != null) {
        tf.filename = nextName!;
        nextName = null;
      }
      if (nextLinkName != null) {
        tf.nameOfLinkedFile = nextLinkName!;
        nextLinkName = null;
      }
      files.add(tf);

      final filename = tf.filename;

      if (tf.isFile) {
        final file = storeData
            ? ArchiveFile.stream(filename, tf.rawContent!)
            : ArchiveFile.noData(filename);

        file.mode = tf.mode;
        file.ownerId = tf.ownerId;
        file.groupId = tf.groupId;
        file.lastModTime = tf.lastModTime;
        if (tf.nameOfLinkedFile != null) {
          file.symbolicLink = tf.nameOfLinkedFile!;
        }

        archive.add(file);

        if (callback != null) {
          callback(file);
        }
      } else {
        final file = ArchiveFile.directory(filename);
        file.mode = tf.mode;
        file.ownerId = tf.ownerId;
        file.groupId = tf.groupId;
        file.lastModTime = tf.lastModTime;
        if (tf.nameOfLinkedFile != null) {
          file.symbolicLink = tf.nameOfLinkedFile!;
        }

        archive.add(file);

        if (callback != null) {
          callback(file);
        }
      }
    }

    return archive;
  }
}

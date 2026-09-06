import 'dart:convert';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'tar/tar_file.dart';

/// Decode a tar formatted buffer into an [Archive] object.
class TarDecoder {
  static const _space = 0x20;
  static const _equals = 0x3d;
  static const _newline = 0x0a;

  final Encoding filenameEncoding;
  List<TarFile> files = [];

  TarDecoder({this.filenameEncoding = const Utf8Codec()});

  /// Decode [data] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  Archive decodeBytes(List<int> data,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    return decodeStream(InputMemoryStream(data),
        verify: verify, storeData: storeData, callback: callback);
  }

  /// Decode [input] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  Archive decodeStream(InputStream input,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    final archive = Archive();
    files.clear();

    String? nextName;
    String? nextLinkName;
    int? nextSize;
    int? nextModTime;
    int? nextOwnerId;
    int? nextGroupId;

    // TarFile paxHeader = null;
    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      final endCheck = input.peekBytes(2).toUint8List();
      if (endCheck.length < 2 || (endCheck[0] == 0 && endCheck[1] == 0)) {
        break;
      }

      if (verify) {
        // A tar header carries a checksum of its own 512 bytes, taking the
        // eight bytes of the checksum field itself as spaces. It is the only
        // thing that tells a tar apart from an unrelated file, since every
        // other field is free-form enough to read as something.
        final h = input.peekBytes(512).toUint8List();
        if (h.length < 512) {
          throw ArchiveException('Invalid tar header');
        }
        var unsigned = 0;
        var signed = 0;
        for (var i = 0; i < 512; ++i) {
          final b = (i >= 148 && i < 156) ? _space : h[i];
          unsigned += b;
          // Implementations that predate unsigned char summed these signed.
          signed += b > 127 ? b - 256 : b;
        }
        // The stored value is octal, padded with spaces or nulls on either
        // side of the digits.
        var p = 148;
        while (p < 156 && (h[p] == _space || h[p] == 0)) {
          p++;
        }
        var digits = '';
        while (p < 156 && h[p] != _space && h[p] != 0) {
          digits += String.fromCharCode(h[p]);
          p++;
        }
        final stored = int.tryParse(digits, radix: 8);
        if (stored != unsigned && stored != signed) {
          throw ArchiveException('Invalid tar header checksum');
        }
      }

      final tf = TarFile.read(input,
          storeData: storeData, encoding: filenameEncoding, size: nextSize);
      // GNU tar puts filenames in files when they exceed tar's native length.
      // Both kinds are named '././@LongLink', so only the type flag says
      // whether the content is the next entry's name or its link target.
      if (tf.filename == '././@LongLink' ||
          tf.typeFlag == TarFile.longName ||
          tf.typeFlag == TarFile.longLinkName) {
        if (tf.typeFlag == TarFile.longLinkName) {
          nextLinkName = tf.rawContent!.readString();
        } else {
          nextName = tf.rawContent!.readString();
        }
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
        // A PAX extended header is a sequence of records formatted as
        // "%d %s=%s\n", where %d is the decimal length of the whole record,
        // including the length field itself and the trailing newline.
        // The records must be walked by that length rather than split on
        // newlines, and they can't be decoded as UTF-8 up front: vendor
        // extensions such as SCHILY.xattr store raw binary values, which may
        // contain both invalid UTF-8 and embedded newlines.
        final records = tf.rawContent!.toUint8List();
        var pos = 0;
        while (pos < records.length) {
          // The length field, terminated by a space.
          var sp = pos;
          while (sp < records.length && records[sp] != _space) {
            sp++;
          }
          if (sp == records.length) {
            break;
          }
          final length = int.tryParse(String.fromCharCodes(records, pos, sp));
          // A record has to at least hold the length field and its space,
          // and can't run past the end of the header.
          if (length == null ||
              length <= sp - pos + 1 ||
              pos + length > records.length) {
            break;
          }
          final recordEnd = pos + length;
          pos = recordEnd;

          // The keyword, terminated by '='. Keywords are portable
          // characters, so decoding them as ASCII is safe.
          var eq = sp + 1;
          while (eq < recordEnd && records[eq] != _equals) {
            eq++;
          }
          if (eq == recordEnd) {
            continue;
          }
          final keyword = String.fromCharCodes(records, sp + 1, eq);
          if (keyword != 'path' &&
              keyword != 'linkpath' &&
              keyword != 'size' &&
              keyword != 'mtime' &&
              keyword != 'uid' &&
              keyword != 'gid') {
            // TODO: support other pax headers.
            continue;
          }

          // The value runs to the end of the record, minus the newline.
          var valueEnd = recordEnd;
          if (records[valueEnd - 1] == _newline) {
            valueEnd--;
          }
          // The values of these keywords are UTF-8, but don't let a malformed
          // one abort the whole archive.
          final value = utf8.decode(records.sublist(eq + 1, valueEnd),
              allowMalformed: true);
          switch (keyword) {
            case 'path':
              nextName = value;
              break;
            case 'linkpath':
              nextLinkName = value;
              break;
            case 'size':
              // A pax size record overrides the header's own field, which is
              // how a file of 8GB or more is stored in this format.
              nextSize = int.tryParse(value);
              break;
            case 'mtime':
              // Stored as seconds, with an optional fractional part that the
              // archive has nowhere to keep. Truncated off the string rather
              // than through a double, which for a long enough fraction would
              // round up and report the wrong second.
              final dot = value.indexOf('.');
              nextModTime =
                  int.tryParse(dot < 0 ? value : value.substring(0, dot));
              break;
            case 'uid':
              nextOwnerId = int.tryParse(value);
              break;
            case 'gid':
              nextGroupId = int.tryParse(value);
              break;
          }
        }
        continue;
      }

      // Fix file attributes.
      nextSize = null;
      if (nextName != null) {
        tf.filename = nextName;
        nextName = null;
      }
      if (nextLinkName != null) {
        tf.nameOfLinkedFile = nextLinkName;
        nextLinkName = null;
      }
      if (nextModTime != null) {
        tf.lastModTime = nextModTime;
        nextModTime = null;
      }
      if (nextOwnerId != null) {
        tf.ownerId = nextOwnerId;
        nextOwnerId = null;
      }
      if (nextGroupId != null) {
        tf.groupId = nextGroupId;
        nextGroupId = null;
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

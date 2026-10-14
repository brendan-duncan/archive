import 'dart:convert';
import 'dart:typed_data';

import '../../util/_zip_name.dart';
import '../../util/archive_exception.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import 'zip_file.dart';

/// Provides information about a file, used by [ZipDecoder].
class ZipFileHeader {
  static const signature = 0x02014b50;
  int versionMadeBy = 0;
  int versionNeededToExtract = 0;
  int generalPurposeBitFlag = 0;
  int compressionMethod = 0;
  int lastModifiedFileTime = 0;
  int lastModifiedFileDate = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  int diskNumberStart = 0;
  int internalFileAttributes = 0;
  int externalFileAttributes = 0;
  int localHeaderOffset = 0;
  String filename = '';
  Uint8List? extraField;
  String fileComment = '';
  ZipFile? file;

  void read(InputStream input,
      {InputStream? fileBytes,
      String? password,
      bool verify = false,
      int prefix = 0,
      Encoding? filenameEncoding}) {
    versionMadeBy = input.readUint16();
    versionNeededToExtract = input.readUint16();
    generalPurposeBitFlag = input.readUint16();
    compressionMethod = input.readUint16();
    lastModifiedFileTime = input.readUint16();
    lastModifiedFileDate = input.readUint16();
    crc32 = input.readUint32();
    compressedSize = input.readUint32();
    uncompressedSize = input.readUint32();
    final fnameLen = input.readUint16();
    final extraLen = input.readUint16();
    final commentLen = input.readUint16();
    diskNumberStart = input.readUint16();
    internalFileAttributes = input.readUint16();
    externalFileAttributes = input.readUint32();
    localHeaderOffset = input.readUint32();

    if (verify && fnameLen + extraLen + commentLen > input.length) {
      throw ArchiveException('zip: central directory header is damaged');
    }

    final nameBytes = input.readBytes(fnameLen).toUint8List();
    filename = zipName(nameBytes, generalPurposeBitFlag, filenameEncoding);
    String? unicodePath;

    if (extraLen > 0) {
      final extraBytes = input.readBytes(extraLen);
      extraField = extraBytes.toUint8List();

      // In some zip or apk files, if the extra field is less than 4 bytes,
      // we ignore it for better compatibility.
      if (extraLen >= 4) {
        final extra = InputMemoryStream(extraField!);
        while (extra.length >= 4) {
          final id = extra.readUint16();
          var size = extra.readUint16();
          final extraBytes = extra.readBytes(size);

          if (id == 1) {
            // Zip64 extended information
            // The following is the layout of the zip64 extended
            // information "extra" block. If one of the size or
            // offset fields in the Local or Central directory
            // record is too small to hold the required data,
            // a Zip64 extended information record is created.
            // The order of the fields in the zip64 extended
            // information record is fixed, but the fields MUST
            // only appear if the corresponding Local or Central
            // directory record field is set to 0xFFFF or 0xFFFFFFFF.
            // Original
            // Size       8 bytes    Original uncompressed file size
            // Compressed
            // Size       8 bytes    Size of compressed data
            // Relative Header
            // Offset     8 bytes    Offset of local header record
            // Disk Start
            // Number     4 bytes    Number of the disk on which
            // this file starts
            if (size >= 8 && uncompressedSize == 0xffffffff) {
              uncompressedSize = extraBytes.readUint64();
              size -= 8;
            }
            if (size >= 8 && compressedSize == 0xffffffff) {
              compressedSize = extraBytes.readUint64();
              size -= 8;
            }
            if (size >= 8 && localHeaderOffset == 0xffffffff) {
              localHeaderOffset = extraBytes.readUint64();
              size -= 8;
            }
            if (size >= 4 && diskNumberStart == 0xffff) {
              diskNumberStart = extraBytes.readUint32();
              size -= 4;
            }
          } else if (id == 0x7075) {
            unicodePath = zipUnicodePath(nameBytes, extraBytes);
          }
        }
      }
    }

    if (commentLen > 0) {
      fileComment = input.readString(size: commentLen);
    }

    if (prefix != 0 &&
        fileBytes != null &&
        !_localHeaderAt(fileBytes, localHeaderOffset + prefix) &&
        _localHeaderAt(fileBytes, localHeaderOffset)) {
      if (verify) {
        throw ArchiveException('zip: central directory is damaged');
      }
      prefix = 0;
    }
    localHeaderOffset += prefix;

    if (fileBytes != null) {
      fileBytes.setPosition(localHeaderOffset);
      file = ZipFile(this);
      file!.read(fileBytes,
          password: password,
          verify: verify,
          filenameEncoding: filenameEncoding);
    }
    if (unicodePath != null) {
      filename = unicodePath;
      file?.filename = unicodePath;
    }
  }

  bool _localHeaderAt(InputStream input, int position) {
    if (position < 0) {
      return false;
    }
    input.setPosition(position);
    return input.length >= 30 && input.readUint32() == ZipFile.zipSignature;
  }

  @override
  String toString() => filename;
}

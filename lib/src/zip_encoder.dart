import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'archive.dart';
import 'archive_file.dart';
import 'util/aes.dart';
import 'util/crc32.dart';
import 'util/input_stream.dart';
import 'util/output_stream.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file.dart';
import 'zip/zip_file_header.dart';
import 'zlib/deflate.dart';

class _ZipFileData {
  late String name;
  int time = 0;
  int date = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  InputStreamBase? compressedData;
  bool compress = true;
  String? comment = '';
  int position = 0;
  int mode = 0;
  bool isFile = true;
}

int? _getTime(DateTime? dateTime) {
  if (dateTime == null) {
    return null;
  }
  final t1 = ((dateTime.minute & 0x7) << 5) | (dateTime.second ~/ 2);
  final t2 = (dateTime.hour << 3) | (dateTime.minute >> 3);
  return ((t2 & 0xff) << 8) | (t1 & 0xff);
}

int? _getDate(DateTime? dateTime) {
  if (dateTime == null) {
    return null;
  }
  final d1 = ((dateTime.month & 0x7) << 5) | dateTime.day;
  final d2 = (((dateTime.year - 1980) & 0x7f) << 1) | (dateTime.month >> 3);
  return ((d2 & 0xff) << 8) | (d1 & 0xff);
}

class _ZipEncoderData {
  int? level;
  late final int? time;
  late final int? date;
  int localFileSize = 0;
  int centralDirectorySize = 0;
  int endOfCentralDirectorySize = 0;
  List<_ZipFileData> files = [];

  _ZipEncoderData(this.level, [DateTime? dateTime]) {
    time = _getTime(dateTime);
    date = _getDate(dateTime);
  }
}

/// Encode an [Archive] object into a Zip formatted buffer.
class ZipEncoder {
  late _ZipEncoderData _data;
  OutputStreamBase? _output;
  final Encoding filenameEncoding;
  final Random _random = Random.secure();
  final String? password;

  ZipEncoder({this.filenameEncoding = const Utf8Codec(), this.password});

  /// Bit 1 of the general purpose flag, File encryption flag
  static const int fileEncryptionBit = 1;

  /// Bit 11 of the general purpose flag, Language encoding flag
  static const int languageEncodingBitUtf8 = 2048;
  static const int _aesEncryptionExtraHeaderId = 0x9901;

  List<int>? encode(Archive archive,
      {int level = Deflate.BEST_SPEED,
      OutputStreamBase? output,
      DateTime? modified,
      bool autoClose = false}) {
    output ??= OutputStream();

    startEncode(output, level: level, modified: modified);
    for (final file in archive.files) {
      addFile(file, autoClose: autoClose);
    }
    endEncode(comment: archive.comment);

    if (output is OutputStream) {
      return output.getBytes();
    }

    return null;
  }

  void startEncode(OutputStreamBase? output,
      {int? level = Deflate.BEST_SPEED, DateTime? modified}) {
    _data = _ZipEncoderData(level, modified);
    _output = output;
  }

  int getFileCrc32(ArchiveFile file) {
    if (file.content == null) {
      return 0;
    }
    if (file.content is InputStreamBase) {
      final s = file.content as InputStreamBase;
      s.reset();
      var crc32 = 0;
      var size = s.length;
      Uint8List? bytes;
      const chunkSize = 1024 * 1024;
      while (size > chunkSize) {
        bytes = s.readBytes(chunkSize).toUint8List(bytes);
        crc32 = getCrc32(bytes, crc32);
        size -= chunkSize;
      }
      if (size > 0) {
        bytes = s.readBytes(size).toUint8List(bytes);
        crc32 = getCrc32(bytes, crc32);
      }
      file.content.reset();
      return crc32;
    }
    return getCrc32(file.content as List<int>);
  }

  // https://stackoverflow.com/questions/62708273/how-unique-is-the-salt-produced-by-this-function
  // length is for the underlying bytes, not the resulting string.
  Uint8List _generateSalt([int length = 94]) {
    return Uint8List.fromList(
        List<int>.generate(length, (i) => _random.nextInt(256)));
  }

  Uint8List? _mac;
  Uint8List? _pwdVer;

  Uint8List _encryptCompressedData(Uint8List data, Uint8List salt) {
    // keySize = 32 bytes (256 bits), because of 0x3 as compression type

    final keySize = 32;

    var derivedKey =
        ZipFile.deriveKey(password!, salt, derivedKeyLength: keySize);
    final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
    final hmacKeyData =
        Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));

    _pwdVer = derivedKey.sublist(keySize * 2, keySize * 2 + 2);

    Aes aes = Aes(keyData, hmacKeyData, keySize, encrypt: true);
    aes.processData(data, 0, data.length);
    _mac = aes.mac;
    return data;
  }

  void addFile(ArchiveFile file, {bool autoClose = true}) {
    final fileData = _ZipFileData();
    _data.files.add(fileData);

    final lastModMS = file.lastModTime * 1000;
    final lastModTime = DateTime.fromMillisecondsSinceEpoch(lastModMS);

    fileData.name = file.name;
    // If the archive modification time was overwritten, use that, otherwise
    // use the lastModTime from the file.
    fileData.time = _data.time ?? _getTime(lastModTime)!;
    fileData.date = _data.date ?? _getDate(lastModTime)!;
    fileData.mode = file.mode;
    fileData.isFile = file.isFile;

    InputStreamBase? compressedData;
    int crc32 = 0;

    // If the user want's to store the file without compressing it,
    // make sure it's decompressed.
    if (!file.compress) {
      if (file.isCompressed) {
        file.decompress();
      }

      compressedData = (file.content is InputStreamBase)
          ? file.content as InputStreamBase
          : InputStream(file.content);

      if (file.crc32 != null) {
        crc32 = file.crc32!;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else if (file.isCompressed &&
        file.compressionType == ArchiveFile.DEFLATE &&
        file.rawContent != null) {
      // If the file is already compressed, no sense in uncompressing it and
      // compressing it again, just pass along the already compressed data.
      compressedData = file.rawContent;

      if (file.crc32 != null) {
        crc32 = file.crc32!;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else if (file.isFile) {
      // Otherwise we need to compress it now.
      crc32 = getFileCrc32(file);

      dynamic bytes = file.content;
      if (bytes is InputStreamBase) {
        bytes = bytes.toUint8List();
      }
      bytes = Deflate(bytes as List<int>, level: _data.level).getBytes();
      compressedData = InputStream(bytes);
    }

    final encodedFilename = filenameEncoding.encode(file.name);
    final comment =
        file.comment != null ? filenameEncoding.encode(file.comment!) : null;

    Uint8List? salt;

    if (password != null && compressedData != null) {
      // https://www.winzip.com/en/support/aes-encryption/#zip-format
      //
      // The size of the salt value depends on the length of the encryption key,
      // as follows:
      //
      // Key size Salt size
      // 128 bits  8 bytes
      // 192 bits 12 bytes
      // 256 bits 16 bytes
      //
      salt = _generateSalt(16);

      final encryptedBytes =
          _encryptCompressedData(compressedData.toUint8List(), salt);

      compressedData = InputStream(encryptedBytes);
    }

    final dataLen = (compressedData?.length ?? 0) +
        (salt?.length ?? 0) +
        (_mac?.length ?? 0) +
        (_pwdVer?.length ?? 0);

    _data.localFileSize += 30 + encodedFilename.length + dataLen;

    _data.centralDirectorySize +=
        46 + encodedFilename.length + (comment != null ? comment.length : 0);

    fileData.crc32 = crc32;
    fileData.compressedSize = dataLen;
    fileData.compressedData = compressedData;
    fileData.uncompressedSize = file.size;
    fileData.compress = file.compress;
    fileData.comment = file.comment;
    fileData.position = _output!.length;

    _writeFile(fileData, _output!, salt: salt);

    fileData.compressedData = null;

    if (autoClose) {
      file.closeSync();
    }
  }

  void endEncode({String? comment = ''}) {
    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(_data.files, comment, _output!);
    if (_output is OutputStreamBase) {
      _output!.flush();
    }
  }

  List<int> _getZip64ExtraData(_ZipFileData fileData) {
    final out = OutputStream();
    // zip64 ID
    out.writeByte(0x01);
    out.writeByte(0x00);
    // field length
    out.writeByte(0x10);
    out.writeByte(0x00);
    // uncompressed size
    out.writeUint64(fileData.uncompressedSize);
    // compressed size
    out.writeUint64(fileData.compressedSize);
    return out.getBytes();
  }

  List<int> _getAexExtraData(_ZipFileData fileData) {
    // https://www.winzip.com/en/support/aes-encryption/#zip-format
    final out = OutputStream();

    final compressionMethod = fileData.compress
        ? ZipFile.zipCompressionDeflate
        : ZipFile.zipCompressionStore;

    out.writeUint16(_aesEncryptionExtraHeaderId); // AE-x encryption ID
    out.writeUint16(0x0007); // field length
    out.writeUint16(0x0001); // AE-1 encryption version
    out.writeBytes(ascii.encode("AE")); // "vendor ID"
    out.writeByte(0x0003); // encryption strength (256-bit)
    out.writeUint16(compressionMethod); // actual compression method

    return out.getBytes();
  }

  void _writeFile(_ZipFileData fileData, OutputStreamBase output,
      {Uint8List? salt}) {
    var filename = fileData.name;

    output.writeUint32(ZipFile.zipFileSignature);

    final needsZip64 = fileData.compressedSize > 0xFFFFFFFF ||
        fileData.uncompressedSize > 0xFFFFFFFF;

    var flags = 0;
    if (filenameEncoding.name == "utf-8") flags |= languageEncodingBitUtf8;
    if (password != null) flags |= fileEncryptionBit;

    final compressionMethod = password != null
        ? ZipFile.zipCompressionAexEncryption
        : fileData.compress
            ? ZipFile.zipCompressionDeflate
            : ZipFile.zipCompressionStore;
    final lastModFileTime = fileData.time;
    final lastModFileDate = fileData.date;
    final crc32 = fileData.crc32;
    final compressedSize = needsZip64 ? 0xFFFFFFFF : fileData.compressedSize;
    final uncompressedSize =
        needsZip64 ? 0xFFFFFFFF : fileData.uncompressedSize;

    final extra = <int>[];
    if (needsZip64) extra.addAll(_getZip64ExtraData(fileData));
    if (password != null) extra.addAll(_getAexExtraData(fileData));

    final compressedData = fileData.compressedData;

    final encodedFilename = filenameEncoding.encode(filename);

    // local file header
    output.writeUint16(version);
    output.writeUint16(flags);
    output.writeUint16(compressionMethod);
    output.writeUint16(lastModFileTime);
    output.writeUint16(lastModFileDate);
    output.writeUint32(crc32);
    output.writeUint32(compressedSize);
    output.writeUint32(uncompressedSize);
    output.writeUint16(encodedFilename.length);
    output.writeUint16(extra.length);
    output.writeBytes(encodedFilename);
    output.writeBytes(extra);

    if (password != null && salt != null) {
      output.writeBytes(salt);
      output.writeBytes(_pwdVer!);
    }

    if (compressedData != null) {
      // local file data
      output.writeInputStream(compressedData);
    }

    if (password != null && _mac != null) {
      output.writeBytes(_mac!);
    }
  }

  List<int> _getZip64CfhData(_ZipFileData fileData) {
    final out = OutputStream();
    // zip64 ID
    out.writeByte(0x01);
    out.writeByte(0x00);
    // field length
    out.writeByte(0x18);
    out.writeByte(0x00);
    // uncompressed size
    out.writeUint64(fileData.uncompressedSize);
    // compressed size
    out.writeUint64(fileData.compressedSize);
    out.writeUint64(fileData.position);
    return out.getBytes();
  }

  void _writeCentralDirectory(
      List<_ZipFileData> files, String? comment, OutputStreamBase output) {
    comment ??= '';
    final encodedComment = filenameEncoding.encode(comment);

    final centralDirPosition = output.length;
    final os = OS_MSDOS;
    var zipNeedsZip64 = false;

    for (final fileData in files) {
      final needsZip64 = fileData.compressedSize > 0xFFFFFFFF ||
          fileData.uncompressedSize > 0xFFFFFFFF ||
          fileData.position > 0xFFFFFFFF;
      zipNeedsZip64 |= needsZip64;

      final versionMadeBy = (os << 8) | version;
      final versionNeededToExtract = version;
      var generalPurposeBitFlag = languageEncodingBitUtf8;
      if (password != null) generalPurposeBitFlag |= fileEncryptionBit;
      final compressionMethod = password != null
          ? ZipFile.zipCompressionAexEncryption
          : fileData.compress
              ? ZipFile.zipCompressionDeflate
              : ZipFile.zipCompressionStore;
      final lastModifiedFileTime = fileData.time;
      final lastModifiedFileDate = fileData.date;
      final crc32 = fileData.crc32;
      final compressedSize = needsZip64 ? 0xFFFFFFFF : fileData.compressedSize;
      final uncompressedSize =
          needsZip64 ? 0xFFFFFFFF : fileData.uncompressedSize;
      final diskNumberStart = 0;
      final internalFileAttributes = 0;
      final externalFileAttributes = fileData.mode << 16;
      /*if (!fileData.isFile) {
        externalFileAttributes |= 0x4000; // ?
      }*/
      final localHeaderOffset = needsZip64 ? 0xFFFFFFFF : fileData.position;

      var extraField = <int>[];
      if (needsZip64) extraField.addAll(_getZip64CfhData(fileData));
      if (password != null) extraField.addAll(_getAexExtraData(fileData));

      final fileComment = fileData.comment ?? '';

      final encodedFilename = filenameEncoding.encode(fileData.name);
      final encodedFileComment = filenameEncoding.encode(fileComment);

      output.writeUint32(ZipFileHeader.SIGNATURE);
      output.writeUint16(versionMadeBy);
      output.writeUint16(versionNeededToExtract);
      output.writeUint16(generalPurposeBitFlag);
      output.writeUint16(compressionMethod);
      output.writeUint16(lastModifiedFileTime);
      output.writeUint16(lastModifiedFileDate);
      output.writeUint32(crc32);
      output.writeUint32(compressedSize);
      output.writeUint32(uncompressedSize);
      output.writeUint16(encodedFilename.length);
      output.writeUint16(extraField.length);
      output.writeUint16(encodedFileComment.length);
      output.writeUint16(diskNumberStart);
      output.writeUint16(internalFileAttributes);
      output.writeUint32(externalFileAttributes);
      output.writeUint32(localHeaderOffset);
      output.writeBytes(encodedFilename);
      output.writeBytes(extraField);
      output.writeBytes(encodedFileComment);
    }

    final numberOfThisDisk = 0;
    final diskWithTheStartOfTheCentralDirectory = 0;
    final totalCentralDirectoryEntriesOnThisDisk = files.length;
    final totalCentralDirectoryEntries = files.length;
    final centralDirectorySize = output.length - centralDirPosition;
    final centralDirectoryOffset = centralDirPosition;

    final needsZip64 = zipNeedsZip64 ||
        totalCentralDirectoryEntriesOnThisDisk > 0xffff ||
        totalCentralDirectoryEntries > 0xffff ||
        centralDirectorySize > 0xffffffff ||
        centralDirPosition > 0xffffffff;

    if (needsZip64) {
      final eocdOffset = output.length;
      output.writeUint32(ZipDirectory.zip64EocdSignature);
      output.writeUint64(0x2c); // size
      output.writeUint16(0x2d); // version (Creator)
      output.writeUint16(0x2d); // version (Viewer)
      output.writeUint32(numberOfThisDisk);
      output.writeUint32(diskWithTheStartOfTheCentralDirectory);
      output.writeUint64(totalCentralDirectoryEntriesOnThisDisk);
      output.writeUint64(totalCentralDirectoryEntries);
      output.writeUint64(centralDirectorySize);
      output.writeUint64(centralDirectoryOffset);

      const totalNumberOfDisks = 1;

      output.writeUint32(ZipDirectory.zip64EocdLocatorSignature);
      output.writeUint32(diskWithTheStartOfTheCentralDirectory);
      output.writeUint64(eocdOffset);
      output.writeUint32(totalNumberOfDisks);
    }

    // End of Central Directory
    output.writeUint32(ZipDirectory.eocdLocatorSignature);
    output.writeUint16(numberOfThisDisk);
    output.writeUint16(
        needsZip64 ? 0xffff : diskWithTheStartOfTheCentralDirectory);
    output.writeUint16(
        needsZip64 ? 0xffff : totalCentralDirectoryEntriesOnThisDisk);
    output.writeUint16(needsZip64 ? 0xffff : totalCentralDirectoryEntries);
    output.writeUint32(needsZip64 ? 0xffffffff : centralDirectorySize);
    output.writeUint32(needsZip64 ? 0xffffffff : centralDirectoryOffset);
    output.writeUint16(encodedComment.length);
    output.writeBytes(encodedComment);
  }

  static const int version = 20;

  // enum OS
  static const int OS_MSDOS = 0;
  static const int OS_UNIX = 3;
  static const int OS_MACINTOSH = 7;
}

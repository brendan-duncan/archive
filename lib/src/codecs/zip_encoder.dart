import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../archive/compression_type.dart';
import '../util/aes.dart';
import '../util/crc32.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'bzip2_encoder.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file.dart';
import 'zip/zip_file_header.dart';
import 'zlib/_zlib_encoder.dart';
import 'zlib/deflate.dart';

class _ZipFileData {
  late String name;
  int time = 0;
  int date = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  InputStream? compressedData;
  CompressionType compression = CompressionType.deflate;
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
  OutputStream? _output;
  final Encoding filenameEncoding;
  final Random _random = Random.secure();
  final String? password;

  ZipEncoder({this.filenameEncoding = const Utf8Codec(), this.password});

  /// Bit 1 of the general purpose flag, File encryption flag
  static const fileEncryptionBit = 1;

  /// Bit 11 of the general purpose flag, Language encoding flag
  static const languageEncodingBitUtf8 = 2048;
  static const _aesEncryptionExtraHeaderId = 0x9901;

  void encodeStream(Archive archive, OutputStream output,
      {int level = DeflateLevel.bestSpeed,
      DateTime? modified,
      bool autoClose = false,
      ArchiveCallback? callback}) {
    startEncode(output, level: level, modified: modified);
    for (final file in archive) {
      add(file, autoClose: autoClose, callback: callback);
    }
    endEncode(comment: archive.comment);
  }

  Uint8List encodeBytes(Archive archive,
      {int level = DeflateLevel.bestSpeed,
      OutputStream? output,
      DateTime? modified,
      bool autoClose = false,
      ArchiveCallback? callback}) {
    output ??= OutputMemoryStream();
    encodeStream(archive, output,
        level: level,
        modified: modified,
        autoClose: autoClose,
        callback: callback);
    return output.getBytes();
  }

  /// Alias for [encodeBytes], kept for backwards compatibility.
  List<int> encode(Archive archive,
          {int level = DeflateLevel.bestSpeed,
          OutputStream? output,
          DateTime? modified,
          bool autoClose = false,
          ArchiveCallback? callback}) =>
      encodeBytes(archive,
          level: level,
          output: output,
          modified: modified,
          autoClose: autoClose,
          callback: callback);

  void startEncode(OutputStream? output,
      {int? level = DeflateLevel.bestSpeed, DateTime? modified}) {
    _data = _ZipEncoderData(level, modified);
    _output = output;
  }

  int getFileCrc32(ArchiveFile file) {
    final content = file.rawContent;
    if (content == null) {
      return 0;
    }
    final s = content.getStream(decompress: false);
    s.reset();
    var crc32 = 0;
    var size = s.length;
    const chunkSize = 1024 * 1024;
    while (size > chunkSize) {
      final bytes = s.readBytes(chunkSize).toUint8List();
      crc32 = getCrc32(bytes, crc32);
      size -= chunkSize;
    }
    if (size > 0) {
      final bytes = s.readBytes(size).toUint8List();
      crc32 = getCrc32(bytes, crc32);
    }
    s.reset();
    return crc32;
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

    final derivedKey =
        ZipFile.deriveKey(password!, salt, derivedKeyLength: keySize);
    final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
    final hmacKeyData =
        Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));

    _pwdVer = derivedKey.sublist(keySize * 2, keySize * 2 + 2);

    final aes = Aes(keyData, hmacKeyData, keySize, encrypt: true);
    aes.processData(data, 0, data.length);
    _mac = aes.mac;
    return data;
  }

  void add(ArchiveFile entry,
      {bool autoClose = true, ArchiveCallback? callback, int? level}) {
    final fileData = _ZipFileData();
    _data.files.add(fileData);

    if (callback != null) {
      callback(entry);
    }

    final lastModMS = entry.lastModTime * 1000;
    final lastModTime = DateTime.fromMillisecondsSinceEpoch(lastModMS);

    fileData.name = entry.name;
    if (!entry.isFile &&
        !fileData.name.endsWith('/') &&
        !fileData.name.endsWith('\\')) {
      fileData.name += '/';
    }
    // If the archive modification time was overwritten, use that, otherwise
    // use the lastModTime from the file.
    fileData.time = _data.time ?? _getTime(lastModTime)!;
    fileData.date = _data.date ?? _getDate(lastModTime)!;
    fileData.mode = entry.mode;
    fileData.isFile = entry.isFile;

    InputStream? compressedData;
    int crc32 = 0;

    var compressionType = entry.compression ?? CompressionType.deflate;

    if (entry.isFile) {
      final file = entry;
      if (file.isCompressed) {
        if (file.compression == CompressionType.none) {
          // If the user want's to store the file without compressing it,
          // make sure it's decompressed.
          compressedData = file.rawContent?.getStream(decompress: true);
        } else {
          // If the file is already compressed, no sense in uncompressing it and
          // compressing it again, just pass along the already compressed data.
          // TODO: handle explicit compression level or type.
          // If the compression level is different, or the compression mode,
          // then we'll need to decompress the file and recompress it.
          compressedData = file.rawContent?.getStream(decompress: false);
          if (file.rawContent is ZipFile) {
            final zipFile = file.rawContent as ZipFile;
            compressionType = zipFile.compressionMethod;
          }
        }

        if (file.crc32 != null) {
          crc32 = file.crc32!;
        } else {
          crc32 = getFileCrc32(file);
        }
      } else {
        // Otherwise we need to compress it now.
        crc32 = getFileCrc32(file);

        if (compressionType == CompressionType.deflate) {
          final content = file.rawContent;
          final output = OutputMemoryStream();
          platformZLibEncoder.encodeStream(
              content!.getStream(decompress: false), output,
              level: level ?? file.compressionLevel ?? _data.level ?? 6,
              raw: true);
          compressedData = InputMemoryStream(output.getBytes());
        } else if (compressionType == CompressionType.bzip2) {
          final content = file.rawContent;
          final output = OutputMemoryStream();
          final bzip2 = BZip2Encoder();
          bzip2.encodeStream(content!.getStream(decompress: false), output);
          compressedData = InputMemoryStream(output.getBytes());
        } else {
          // no compression
          compressedData = file.rawContent?.getStream(decompress: false);
        }
      }
    }

    final encodedFilename = filenameEncoding.encode(entry.name);
    final comment =
        entry.comment != null ? filenameEncoding.encode(entry.comment!) : null;

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

      compressedData = InputMemoryStream(encryptedBytes);
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
    fileData.uncompressedSize = entry.size;
    fileData.compression = compressionType;
    fileData.comment = entry.comment;
    fileData.position = _output!.length;

    _writeFile(fileData, _output!, salt: salt);

    fileData.compressedData = null;

    /*if (entry.isDirectory) {
      for (final file in entry) {
        add(file, autoClose: autoClose, callback: callback);
      }
    }*/

    if (autoClose) {
      entry.closeSync();
    }
  }

  void endEncode({String? comment = ''}) {
    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(_data.files, comment, _output!);
    if (_output != null) {
      _output!.flush();
    }
  }

  List<int> _getZip64ExtraData(_ZipFileData fileData) {
    final out = OutputMemoryStream();
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
    final out = OutputMemoryStream();

    final compressionMethod = fileData.compression == CompressionType.deflate
        ? ZipFile.zipCompressionDeflate
        : fileData.compression == CompressionType.bzip2
            ? ZipFile.zipCompressionBZip2
            : ZipFile.zipCompressionStore;

    out.writeUint16(_aesEncryptionExtraHeaderId); // AE-x encryption ID
    out.writeUint16(0x0007); // field length
    out.writeUint16(0x0001); // AE-1 encryption version
    out.writeBytes(ascii.encode("AE")); // "vendor ID"
    out.writeByte(0x0003); // encryption strength (256-bit)
    out.writeUint16(compressionMethod); // actual compression method

    return out.getBytes();
  }

  void _writeFile(_ZipFileData fileData, OutputStream output,
      {Uint8List? salt}) {
    var filename = fileData.name;

    output.writeUint32(ZipFile.zipSignature);

    final needsZip64 = fileData.compressedSize > 0xFFFFFFFF ||
        fileData.uncompressedSize > 0xFFFFFFFF;

    var flags = 0;
    if (filenameEncoding.name == "utf-8") {
      flags |= languageEncodingBitUtf8;
    }
    if (password != null) {
      flags |= fileEncryptionBit;
    }

    final compressionMethod = password != null
        ? ZipFile.zipCompressionAexEncryption
        : fileData.compression == CompressionType.deflate
            ? ZipFile.zipCompressionDeflate
            : fileData.compression == CompressionType.bzip2
                ? ZipFile.zipCompressionBZip2
                : ZipFile.zipCompressionStore;
    final lastModFileTime = fileData.time;
    final lastModFileDate = fileData.date;
    final crc32 = fileData.crc32;
    final compressedSize = needsZip64 ? 0xFFFFFFFF : fileData.compressedSize;
    final uncompressedSize =
        needsZip64 ? 0xFFFFFFFF : fileData.uncompressedSize;

    final extra = <int>[];
    if (needsZip64) {
      extra.addAll(_getZip64ExtraData(fileData));
    }
    if (password != null) {
      extra.addAll(_getAexExtraData(fileData));
    }

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
      output.writeStream(compressedData);
    }

    if (password != null && _mac != null) {
      output.writeBytes(_mac!);
    }
  }

  List<int> _getZip64CfhData(_ZipFileData fileData) {
    final out = OutputMemoryStream();
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
      List<_ZipFileData> files, String? comment, OutputStream output) {
    comment ??= '';
    final encodedComment = filenameEncoding.encode(comment);

    final centralDirPosition = output.length;
    final os = _osMSDos;
    var zipNeedsZip64 = false;

    for (final fileData in files) {
      final needsZip64 = fileData.compressedSize > 0xFFFFFFFF ||
          fileData.uncompressedSize > 0xFFFFFFFF ||
          fileData.position > 0xFFFFFFFF;
      zipNeedsZip64 |= needsZip64;

      final versionMadeBy = (os << 8) | version;
      final versionNeededToExtract = version;
      var generalPurposeBitFlag = languageEncodingBitUtf8;
      if (password != null) {
        generalPurposeBitFlag |= fileEncryptionBit;
      }
      final compressionMethod = password != null
          ? ZipFile.zipCompressionAexEncryption
          : fileData.compression == CompressionType.deflate
              ? ZipFile.zipCompressionDeflate
              : fileData.compression == CompressionType.bzip2
                  ? ZipFile.zipCompressionBZip2
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
        externalFileAttributes |= 0x4000;
      }*/
      final localHeaderOffset = needsZip64 ? 0xFFFFFFFF : fileData.position;

      var extraField = <int>[];
      if (needsZip64) {
        extraField.addAll(_getZip64CfhData(fileData));
      }
      if (password != null) {
        extraField.addAll(_getAexExtraData(fileData));
      }

      final fileComment = fileData.comment ?? '';

      final encodedFilename = filenameEncoding.encode(fileData.name);
      final encodedFileComment = filenameEncoding.encode(fileComment);

      output.writeUint32(ZipFileHeader.signature);
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
    output.writeUint32(ZipDirectory.eocdSignature);
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

  static const version = 20;

  // enum OS
  static const _osMSDos = 0;
}

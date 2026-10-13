import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../archive/compression_type.dart';
import '../util/_link_target.dart';
import '../util/aes.dart';
import '../util/archive_exception.dart';
import '../util/byte_order.dart';
import '../util/chunked_sink.dart';
import '../util/crc32.dart';
import '../util/file_content.dart';
import '../util/input_decode_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'bzip2/bzip2_chunked.dart';
import 'bzip2_encoder.dart';
import 'xz/xz_chunked.dart';
import 'xz_encoder.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file.dart';
import 'zip/zip_file_header.dart';
import 'zlib/_zlib_encoder.dart';
import 'zlib/_zlib_encoder_base.dart';
import 'zlib/deflate.dart';
import 'zstd/zstd_chunked.dart';
import 'zstd_encoder.dart';

class _Crc32Sink implements Sink<List<int>> {
  var value = 0;

  @override
  void add(List<int> data) => value = getCrc32(data, value);

  @override
  void close() {}
}

class _ZipFileData {
  late String name;
  int time = 0;
  int date = 0;
  int modified = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  InputStream? compressedData;

  /// Set instead of [compressedData] where the entry is deflated straight into
  /// the output rather than into a buffer first
  InputStream? source;
  Aes? cipher;

  /// What [source] is compressed at, resolved where the entry is added: the
  /// buffered path reads the same three places and must not disagree with it
  int level = 6;

  /// General purpose bit 3, which says the check and the sizes follow the
  /// data. The central directory has to carry it too, or a reader that
  /// compares the two headers identifies the pair broken
  bool deferred = false;

  /// Set on a streamed entry that deflate may grow past 4 GB. Its local header
  /// carries zip64 and the sizes behind its data take 8 bytes each
  bool zip64 = false;

  CompressionType compression = CompressionType.deflate;
  int? method;
  int aesVersion = 1;
  bool lzmaEndMarker = false;
  int methodFlags = 0;
  String? comment = '';
  int position = 0;

  /// The general purpose flags the local header was written with, which the
  /// central directory has to repeat: readers such as 7-Zip check that they
  /// agree.
  int flags = 0;

  bool get encrypted => flags & ZipEncoder.fileEncryptionBit != 0;
  int mode = 0;
  bool isFile = true;
  bool unixHost = false;
}

DateTime _dosRange(DateTime t) => t.year < 1980
    ? DateTime(1980)
    : t.year > 2107
        ? DateTime(2107, 12, 31, 23, 59, 58)
        : t;

int? _getTime(DateTime? dateTime) {
  if (dateTime == null) {
    return null;
  }
  final t = _dosRange(dateTime);
  final t1 = ((t.minute & 0x7) << 5) | (t.second ~/ 2);
  final t2 = (t.hour << 3) | (t.minute >> 3);
  return ((t2 & 0xff) << 8) | (t1 & 0xff);
}

int? _getDate(DateTime? dateTime) {
  if (dateTime == null) {
    return null;
  }
  final t = _dosRange(dateTime);
  final d1 = ((t.month & 0x7) << 5) | t.day;
  final d2 = (((t.year - 1980) & 0x7f) << 1) | (t.month >> 3);
  return ((d2 & 0xff) << 8) | (d1 & 0xff);
}

class _ZipEncoderData {
  int? level;
  late final int? time;
  late final int? date;
  late final int? seconds;
  List<_ZipFileData> files = [];

  _ZipEncoderData(this.level, [DateTime? dateTime]) {
    // DOS fields hold local time. Hours of UTC DateTime written as they are
    // read back shifted by the reader's time zone offset
    time = _getTime(dateTime?.toLocal());
    date = _getDate(dateTime?.toLocal());
    seconds = dateTime == null ? null : dateTime.millisecondsSinceEpoch ~/ 1000;
  }
}

/// Encode an [Archive] object into a Zip formatted buffer.
class ZipEncoder {
  late _ZipEncoderData _data;
  OutputStream? _output;
  ByteOrder? _held;
  final Encoding filenameEncoding;
  // Lazy, since only a password needs it. Eager, dart2js and Node cannot even
  // build a ZipEncoder: Random.secure() throws there
  late final Random _random = Random.secure();
  final String? password;

  /// Streams each entry's deflated data straight to the output and writes its
  /// CRC and sizes after it (bit 3), so memory stays at one deflate buffer.
  /// Off by default because the output differs from [encodeBytes].
  final bool streamed;

  ZipEncoder(
      {this.filenameEncoding = const Utf8Codec(),
      this.password,
      this.streamed = false});

  static const _dataDescriptorSignature = 0x08074b50;

  /// An entry up to this size is compressed and written in one piece. A stream
  /// encoder on each of 10000 entries of 100 to 400 bytes was 29% slower with
  /// zstd and 37% with xz
  static const _bufferedMax = 1 << 20;

  /// Bit 1 of the general purpose flag, File encryption flag
  static const fileEncryptionBit = 1;

  /// Bit 3 of the general purpose flag, CRC and sizes in data descriptor
  static const dataDescriptorBit = 8;

  /// Bit 11 of the general purpose flag, Language encoding flag
  static const languageEncodingBitUtf8 = 2048;
  static const _aesEncryptionExtraHeaderId = 0x9901;

  void encodeStream(Archive archive, OutputStream output,
      {int level = DeflateLevel.bestSpeed,
      DateTime? modified,
      bool autoClose = false,
      ArchiveCallback? callback}) {
    startEncode(output, level: level, modified: modified);
    try {
      for (final file in archive) {
        add(file, autoClose: autoClose, callback: callback);
      }
      endEncode(comment: archive.comment);
    } finally {
      _restoreOrder();
    }
  }

  Uint8List encodeBytes(Archive archive,
      {int level = DeflateLevel.bestSpeed,
      OutputStream? output,
      DateTime? modified,
      bool autoClose = false,
      ArchiveCallback? callback}) {
    if (output == null) {
      var headers = 22;
      var stored = 0;
      for (final file in archive) {
        headers += 128 + 3 * file.name.length;
        final content = file.rawContent;
        if (file.compression == CompressionType.none &&
            content is FileContentMemory) {
          stored += content.length;
        }
      }
      output = stored > 0
          ? OutputMemoryStream(size: headers + stored)
          : OutputMemoryStream();
    }
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
    if (output != null) {
      _held = output.byteOrder;
      output.byteOrder = ByteOrder.littleEndian;
    }
  }

  // Java's ZipInputStream refuses a stored entry with a data descriptor, and
  // EPUB and ODF need their stored mimetype entry without one (#421)
  bool _canWriteSizesFirst(FileContent content, CompressionType compression) {
    if (content is FileContentMemory) {
      return true;
    }
    return compression == CompressionType.none &&
        password == null &&
        (content is ZipFile ||
            (content is FileContentStream &&
                content.stream is! InputDecodeStream));
  }

  int getFileCrc32(ArchiveFile file) {
    final content = file.rawContent;
    if (content == null) {
      return 0;
    }
    // Crc is updated from decompressed output for RAM efficiency: 498 MB
    // against 80 MB on 200 MB file
    if (content.isCompressed) {
      final crc = _Crc32Sink();
      final output = SinkOutputStream(crc);
      content.decompress(output);
      output.flush();
      return crc.value;
    }
    final s = content.getStream(decompress: false);
    s.reset();
    var crc32 = 0;
    if (s is! InputMemoryStream) {
      final chunk = Uint8List(min(s.length, 1024 * 1024));
      while (true) {
        final got = s.readInto(chunk, 0, chunk.length);
        if (got <= 0) {
          break;
        }
        crc32 = getCrc32(Uint8List.sublistView(chunk, 0, got), crc32);
      }
      s.reset();
      return crc32;
    }
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

  Aes _startEncryption(Uint8List salt) {
    // keySize = 32 bytes (256 bits), because of 0x3 as compression type

    final keySize = 32;

    final derivedKey =
        ZipFile.deriveKey(password!, salt, derivedKeyLength: keySize);
    final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
    final hmacKeyData =
        Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));

    _pwdVer = derivedKey.sublist(keySize * 2, keySize * 2 + 2);

    return Aes(keyData, hmacKeyData, keySize, encrypt: true);
  }

  Uint8List _encryptCompressedData(Uint8List data, Uint8List salt) {
    final aes = _startEncryption(salt);
    aes.processData(data, 0, data.length);
    _mac = aes.mac;
    return data;
  }

  void add(ArchiveFile entry,
          {bool autoClose = true, ArchiveCallback? callback, int? level}) =>
      addHeader(entry, autoClose: autoClose, callback: callback, level: level)
          ?.finish();

  /// Writes [entry]'s local header and returns its body. Null if the entry is
  /// already written whole, everything but a streamed deflate and, without a
  /// password, an entry with more than 1 MiB to write
  ZipEntryBody? addHeader(ArchiveFile entry,
      {bool autoClose = true, ArchiveCallback? callback, int? level}) {
    final fileData = _ZipFileData();

    // An entry with no content is not encrypted. Without this reset it keeps
    // the last entry's mac, so its header declares 12 bytes it never writes
    // and every local header after it is off by 2
    _mac = null;
    _pwdVer = null;

    if (callback != null) {
      callback(entry);
    }

    final lastModMS = entry.lastModTime * 1000;
    final lastModTime = DateTime.fromMillisecondsSinceEpoch(lastModMS);

    // The zip format requires forward slashes as the path separator
    // (APPNOTE 4.4.17). Normalize backslashes that can creep in from
    // Windows paths so the archive isn't corrupt on other platforms.
    fileData.name = entry.name.replaceAll('\\', '/');
    if (!entry.isFile && !fileData.name.endsWith('/')) {
      fileData.name += '/';
    }
    if (fileData.name.length > 0x3fff &&
        filenameEncoding.encode(fileData.name).length > 0xffff) {
      throw ArchiveException('zip: name is longer than 65535 bytes');
    }
    final comment = entry.comment;
    if (comment != null &&
        comment.length > 0x3fff &&
        filenameEncoding.encode(comment).length > 0xffff) {
      throw ArchiveException('zip: comment is longer than 65535 bytes');
    }
    // If the archive modification time was overwritten, use that, otherwise
    // use the lastModTime from the file.
    fileData.time = _data.time ?? _getTime(lastModTime)!;
    fileData.date = _data.date ?? _getDate(lastModTime)!;
    fileData.modified = _data.seconds ?? entry.lastModTime;
    fileData.mode = entry.mode;
    fileData.isFile = entry.isFile;

    InputStream? compressedData;
    var ownsData = false;
    int crc32 = 0;

    var compressionType = entry.compression ?? CompressionType.deflate;
    // A directory has no data, and a compression method on it makes a reader
    // decompress an empty stream
    if (!entry.isFile) {
      compressionType = CompressionType.none;
    }

    var linkSize = -1;
    if (entry.isSymbolicLink) {
      final target = utf8.encode(linkTarget(entry));
      compressionType = CompressionType.none;
      compressedData = InputMemoryStream(target);
      ownsData = true;
      crc32 = getCrc32(target);
      linkSize = target.length;
      fileData.mode = 0xa000 | (entry.mode & 0xfff);
      fileData.unixHost = true;
    } else if (entry.isFile &&
        entry.rawContent is ZipFile &&
        (entry.rawContent as ZipFile).unsupportedMethod != null) {
      final zipFile = entry.rawContent as ZipFile;
      if (!zipFile.hasCrc32) {
        if (password == null) {
          throw ArchiveException(
              'zip: CRC32 of ${entry.name} is unknown without AES');
        }
        fileData.aesVersion = 2;
      }
      compressionType = CompressionType.none;
      compressedData = zipFile.getStream(decompress: false);
      crc32 = zipFile.crc32;
      fileData.method = zipFile.unsupportedMethod;
      fileData.methodFlags = zipFile.flags & 0x06;
    } else if (entry.isFile) {
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
            fileData.lzmaEndMarker = zipFile.flags & 0x02 != 0;
          }
        }

        if (file.crc32 != null) {
          crc32 = file.crc32!;
        } else {
          crc32 = getFileCrc32(file);
        }
      } else {
        // Otherwise we need to compress it now.
        // Package has no compressing LZMA encoder, XZEncoder only stores LZMA2
        // chunks, so we write lzma entry with deflate
        if (compressionType == CompressionType.lzma) {
          compressionType = CompressionType.deflate;
        }
        if (compressionType == CompressionType.xz &&
            file.size == 0 &&
            (file.rawContent?.length ?? 0) == 0) {
          compressionType = CompressionType.none;
        }
        final content = file.rawContent;
        final viaStream =
            content != null && !_canWriteSizesFirst(content, compressionType);
        final streamedDeflate = (streamed || viaStream) &&
            compressionType == CompressionType.deflate;
        final streamedOther = (compressionType == CompressionType.zstd ||
                compressionType == CompressionType.xz ||
                compressionType == CompressionType.bzip2) &&
            content != null &&
            (viaStream || streamed && file.size > _bufferedMax);
        final streamedStored =
            viaStream && compressionType == CompressionType.none;
        if (!streamedDeflate && !streamedOther && !streamedStored) {
          crc32 = getFileCrc32(file);
        }

        final chosen = level ?? file.compressionLevel ?? _data.level ?? 6;
        final zstd = compressionType == CompressionType.zstd;
        final minLevel = zstd ? zstdMinLevel : -1;
        final maxLevel = zstd ? zstdMaxLevel : 9;
        if (chosen < minLevel || chosen > maxLevel) {
          throw ArgumentError.value(
              chosen, 'level', 'Must be $minLevel to $maxLevel');
        }
        // An entry with no content at all cannot be deflated: a zero length
        // deflate stream is two bytes, not none, and a reader given neither
        // identifies the entry corrupt
        if (file.rawContent == null) {
          compressionType = CompressionType.none;
          compressedData = InputMemoryStream(Uint8List(0));
        } else if (streamedOther) {
          final requested = level ?? file.compressionLevel ?? _data.level;
          fileData.level = requested == null || requested == 0
              ? zstdDefaultLevel
              : requested;
          fileData.source = file.rawContent?.getStream(decompress: false);
          fileData.source?.reset();
          // Of zstd, xz and bzip2, bzip2 grows data that does not compress the
          // most, by up to 1% and 600 bytes
          final size = entry.size;
          fileData.zip64 = size + (size >> 6) + 4096 > 0xFFFFFFFF;
        } else if (streamedDeflate) {
          fileData.level = chosen;
          fileData.source = file.rawContent?.getStream(decompress: false);
          fileData.source?.reset();
          // Deflate grows data that does not compress. compressBound in zlib
          // gives the worst case
          final size = entry.size;
          fileData.zip64 =
              size + (size >> 12) + (size >> 14) + (size >> 25) + 13 >
                  0xFFFFFFFF;
        } else if (streamedStored) {
          fileData.source = file.rawContent?.getStream(decompress: false);
          fileData.source?.reset();
          final size = entry.size;
          fileData.zip64 = size + 4096 > 0xFFFFFFFF;
        } else if (compressionType == CompressionType.deflate) {
          final content = file.rawContent;
          final output = OutputMemoryStream();
          final source = content!.getStream(decompress: false);
          final at = source.position;
          try {
            platformZLibEncoder.encodeStream(source, output,
                level: chosen, raw: true);
          } finally {
            source.setPosition(at);
          }
          compressedData = InputMemoryStream(output.getBytes());
          ownsData = true;
        } else if (compressionType == CompressionType.bzip2) {
          final content = file.rawContent;
          final output = OutputMemoryStream();
          final bzip2 = BZip2Encoder();
          final source = content!.getStream(decompress: false);
          final at = source.position;
          try {
            bzip2.encodeStream(source, output);
          } finally {
            source.setPosition(at);
          }
          compressedData = InputMemoryStream(output.getBytes());
          ownsData = true;
        } else if (compressionType == CompressionType.zstd ||
            compressionType == CompressionType.xz) {
          final requested = level ?? file.compressionLevel ?? _data.level;
          final output = OutputMemoryStream();
          final source = file.rawContent!.getStream(decompress: false);
          final at = source.position;
          try {
            if (compressionType == CompressionType.zstd) {
              ZstdEncoder().encodeStream(source, output,
                  level: requested == 0 ? null : requested);
            } else {
              XZEncoder().encodeStream(source, output);
            }
          } finally {
            source.setPosition(at);
          }
          compressedData = InputMemoryStream(output.getBytes());
          ownsData = true;
        } else {
          // no compression
          compressedData = file.rawContent?.getStream(decompress: false);
        }
      }
    }

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

      final data = compressedData.toUint8List();
      final encryptedBytes = _encryptCompressedData(
          ownsData || compressedData is! InputMemoryStream
              ? data
              : Uint8List.fromList(data),
          salt);

      compressedData = InputMemoryStream(encryptedBytes);
    } else if (password != null && fileData.source != null) {
      salt = _generateSalt(16);
      fileData.cipher = _startEncryption(salt);
    }

    final dataLen = (compressedData?.length ?? 0) +
        (salt?.length ?? 0) +
        (_mac?.length ?? 0) +
        (_pwdVer?.length ?? 0);
    // Not known until the deflate has run, and filled in by _writeFile
    final deferred = fileData.source != null;
    fileData.deferred = deferred;

    fileData.crc32 = crc32;
    fileData.compressedSize = deferred ? 0 : dataLen;
    fileData.compressedData = compressedData;
    // We write entry.size as declared, since zip64 choice and its tests use it.
    // If size differs from content, ZipDecoder(verify: true) and 7z reject
    // entry, so developer must keep size equal to content length
    fileData.uncompressedSize = entry.size;
    if (linkSize >= 0) {
      fileData.uncompressedSize = linkSize;
    }
    fileData.compression = compressionType;
    fileData.comment = entry.comment;
    fileData.position = _output!.length;

    void done() {
      fileData.compressedData = null;
      fileData.source = null;
      if (autoClose) {
        entry.closeSync();
      }
    }

    // After possible error so that archive remains valid after following adds
    _data.files.add(fileData);
    final body = _writeFile(fileData, _output!, salt: salt, done: done);
    if (body == null) {
      done();
    }
    return body;
  }

  void endEncode({String? comment = ''}) {
    if (comment != null &&
        comment.length > 0x3fff &&
        filenameEncoding.encode(comment).length > 0xffff) {
      throw ArchiveException('zip: archive comment is longer than 65535 bytes');
    }
    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(_data.files, comment, _output!);
    if (_output != null) {
      _output!.flush();
    }
    _restoreOrder();
  }

  void _restoreOrder() {
    final held = _held;
    if (held != null) {
      _output?.byteOrder = held;
      _held = null;
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

  int _compressionMethod(_ZipFileData fileData) =>
      fileData.method ??
      (fileData.compression == CompressionType.deflate
          ? ZipFile.zipCompressionDeflate
          : fileData.compression == CompressionType.bzip2
              ? ZipFile.zipCompressionBZip2
              : fileData.compression == CompressionType.lzma
                  ? ZipFile.zipCompressionLzma
                  : fileData.compression == CompressionType.zstd
                      ? ZipFile.zipCompressionZstd
                      : fileData.compression == CompressionType.xz
                          ? ZipFile.zipCompressionXz
                          : ZipFile.zipCompressionStore);

  List<int> _getUtExtraData(_ZipFileData fileData) {
    final seconds = fileData.modified % 0x100000000;
    return [
      0x55,
      0x54,
      5,
      0,
      1,
      seconds % 256,
      seconds ~/ 0x100 % 256,
      seconds ~/ 0x10000 % 256,
      seconds ~/ 0x1000000,
    ];
  }

  List<int> _getAexExtraData(_ZipFileData fileData) {
    // https://www.winzip.com/en/support/aes-encryption/#zip-format
    final out = OutputMemoryStream();

    final compressionMethod = _compressionMethod(fileData);

    out.writeUint16(_aesEncryptionExtraHeaderId); // AE-x encryption ID
    out.writeUint16(0x0007); // field length
    out.writeUint16(fileData.aesVersion); // AE-1 or AE-2 encryption version
    out.writeBytes(ascii.encode("AE")); // "vendor ID"
    out.writeByte(0x0003); // encryption strength (256-bit)
    out.writeUint16(compressionMethod); // actual compression method

    return out.getBytes();
  }

  ZipEntryBody? _writeFile(_ZipFileData fileData, OutputStream output,
      {Uint8List? salt, required void Function() done}) {
    var filename = fileData.name;

    output.writeUint32(ZipFile.zipSignature);

    final needsZip64 = fileData.compressedSize > 0xFFFFFFFF ||
        fileData.uncompressedSize > 0xFFFFFFFF;

    var flags = 0;
    if (fileData.deferred) {
      flags |= dataDescriptorBit;
    }
    if (filenameEncoding.name == "utf-8") {
      flags |= languageEncodingBitUtf8;
    }
    // Only an entry with data is encrypted; a directory has none.
    if (password != null && salt != null) {
      flags |= fileEncryptionBit;
    }
    final lzma = fileData.compression == CompressionType.lzma;
    if (lzma && fileData.lzmaEndMarker) {
      flags |= 0x02;
    }
    flags |= fileData.methodFlags;
    fileData.flags = flags;
    final encrypted = fileData.encrypted;

    final compressionMethod = encrypted
        ? ZipFile.zipCompressionAexEncryption
        : _compressionMethod(fileData);
    final lastModFileTime = fileData.time;
    final lastModFileDate = fileData.date;
    // With bit 3 the three of them are zero here and carried behind the data
    final deferred = fileData.deferred;
    final crc32 = deferred ? 0 : fileData.crc32;
    final compressedSize =
        deferred ? 0 : (needsZip64 ? 0xFFFFFFFF : fileData.compressedSize);
    final uncompressedSize =
        deferred ? 0 : (needsZip64 ? 0xFFFFFFFF : fileData.uncompressedSize);

    // Info-ZIP writes a streamed zip64 entry this way. The local sizes are
    // 0xFFFFFFFF and the zip64 field holds two zero sizes
    final extra = <int>[];
    if (needsZip64 && !fileData.zip64) {
      extra.addAll(_getZip64ExtraData(fileData));
    }
    if (fileData.zip64) {
      extra.addAll(const [0x01, 0x00, 0x10, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]);
      extra.addAll(const [0, 0, 0, 0, 0, 0, 0, 0]);
    }
    // archive 4.3.0 reads local extra 2 bytes at a time after AES record and
    // throws RangeError on 9-byte UT field, and EPUB and ODF need a stored
    // mimetype entry without one, so every entry keeps UT only in central
    if (encrypted) {
      extra.addAll(_getAexExtraData(fileData));
    }

    final compressedData = fileData.compressedData;

    final encodedFilename = filenameEncoding.encode(filename);

    // local file header
    output.writeUint16(lzma
        ? _versionLzma
        : needsZip64 || fileData.zip64
            ? 45
            : version);
    output.writeUint16(flags);
    output.writeUint16(compressionMethod);
    output.writeUint16(lastModFileTime);
    output.writeUint16(lastModFileDate);
    output.writeUint32(crc32);
    output.writeUint32(fileData.zip64 ? 0xFFFFFFFF : compressedSize);
    output.writeUint32(fileData.zip64 ? 0xFFFFFFFF : uncompressedSize);
    output.writeUint16(encodedFilename.length);
    output.writeUint16(extra.length);
    output.writeBytes(encodedFilename);
    output.writeBytes(extra);

    if (password != null && salt != null) {
      output.writeBytes(salt);
      output.writeBytes(_pwdVer!);
    }

    final source = fileData.source;
    if (source != null) {
      // Deflated straight into the output, so its length is only known once it
      // is there, and it goes into the descriptor behind the data
      return ZipEntryBody._(source, output, fileData, done);
    } else if (compressedData != null &&
        password == null &&
        compressedData.length > _bufferedMax) {
      return ZipEntryBody._(compressedData, output, fileData, done);
    } else if (compressedData != null) {
      // local file data
      final at = compressedData.position;
      try {
        output.writeStream(compressedData);
      } finally {
        compressedData.setPosition(at);
      }
    }

    if (password != null && salt != null && _mac != null) {
      output.writeBytes(_mac!);
    }
    return null;
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

      final madeBy = filenameEncoding.name == "utf-8" &&
              fileData.name.codeUnits.any((c) => c > 0x7f)
          ? _versionAnsiNames
          : version;
      final versionMadeBy = ((fileData.unixHost ? _osUnix : os) << 8) | madeBy;
      final lzma = fileData.compression == CompressionType.lzma;
      final versionNeededToExtract = lzma
          ? _versionLzma
          : fileData.zip64 || needsZip64
              ? 45
              : version;
      // Must match the local header. If only this one sets bit 11, a reader
      // decodes a latin1 name as UTF-8
      var generalPurposeBitFlag = 0;
      if (filenameEncoding.name == "utf-8") {
        generalPurposeBitFlag |= languageEncodingBitUtf8;
      }
      if (fileData.deferred) {
        generalPurposeBitFlag |= dataDescriptorBit;
      }
      if (fileData.encrypted) {
        generalPurposeBitFlag |= fileEncryptionBit;
      }
      if (lzma && fileData.lzmaEndMarker) {
        generalPurposeBitFlag |= 0x02;
      }
      generalPurposeBitFlag |= fileData.methodFlags;
      final compressionMethod = fileData.encrypted
          ? ZipFile.zipCompressionAexEncryption
          : _compressionMethod(fileData);
      final lastModifiedFileTime = fileData.time;
      final lastModifiedFileDate = fileData.date;
      final crc32 = fileData.crc32;
      final compressedSize = needsZip64 ? 0xFFFFFFFF : fileData.compressedSize;
      final uncompressedSize =
          needsZip64 ? 0xFFFFFFFF : fileData.uncompressedSize;
      final diskNumberStart = 0;
      final internalFileAttributes = 0;
      var externalFileAttributes = fileData.mode << 16;
      if (!fileData.isFile) {
        // The MS-DOS directory attribute, which is what readers check for an
        // archive made on MS-DOS.
        externalFileAttributes |= 0x10;
      }
      final localHeaderOffset = needsZip64 ? 0xFFFFFFFF : fileData.position;

      var extraField = <int>[];
      if (needsZip64) {
        extraField.addAll(_getZip64CfhData(fileData));
      }
      if (fileData.encrypted) {
        extraField.addAll(_getAexExtraData(fileData));
      }
      extraField.addAll(_getUtExtraData(fileData));

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
  static const _versionLzma = 63;
  static const _versionAnsiNames = 40;

  // enum OS
  static const _osMSDos = 0;
  static const _osUnix = 3;
}

/// Writes one entry a piece at a time. Call [step] until it returns false,
/// then [finish]. This lets a caller pass the bytes on before the whole entry
/// is compressed
class ZipEntryBody {
  ZipEntryBody._(this._source, this._output, this._data, this._done)
      : _before = _output.length - (_data.cipher == null ? 0 : 18),
        _start = _source.position,
        _aes = _data.cipher == null
            ? null
            : _AesOutputStream(_output, _data.cipher!);

  /// How much one [step] deflates. It still feeds the deflate in 1024 byte
  /// reads, so the output bytes do not change
  static const _piece = 64 * 1024;

  final InputStream _source;
  final OutputStream _output;
  final _ZipFileData _data;
  final void Function() _done;
  final int _before;
  final int _start;
  final _AesOutputStream? _aes;
  late final OutputStream _out = _aes ?? _output;
  var _read = 0;

  /// Null on the web, where deflate only runs whole, and on an entry that is
  /// not a deflate. Then [finish] does a web deflate in one call
  late final Sink<List<int>>? _sink =
      _data.deferred && _data.compression == CompressionType.deflate
          ? platformZLibEncoder.startEncode(_out, level: _data.level, raw: true)
          : null;

  Sink<List<int>>? _encoder;

  var _closed = false;

  bool step() {
    if (!_data.deferred) {
      return _copy();
    }
    if (_data.compression == CompressionType.none) {
      return _store();
    }
    if (_data.compression != CompressionType.deflate) {
      return _encode();
    }
    final sink = _sink;
    if (sink == null || _closed || _source.isEOS) {
      return false;
    }
    var left = _piece;
    while (left > 0 && !_source.isEOS) {
      final take = _source.length < 1024 ? _source.length : 1024;
      // This body runs under `while (step())`. A break returns true and that
      // loop spins forever. Returning false ends the body
      // A caller's own InputStream may report a length that its isEOS does not
      // agree with. Without this the loop takes nothing and never ends
      if (take <= 0) {
        return false;
      }
      final bytes = _source.readBytes(take).toUint8List();
      _data.crc32 = getCrc32(bytes, _data.crc32);
      _read += bytes.length;
      sink.add(bytes);
      left -= take;
    }
    return true;
  }

  bool _store() {
    final take = _source.length < _piece ? _source.length : _piece;
    if (_closed || take <= 0) {
      return false;
    }
    final bytes = _source.readBytes(take).toUint8List();
    _data.crc32 = getCrc32(bytes, _data.crc32);
    _read += bytes.length;
    _out.writeBytes(bytes);
    return true;
  }

  bool _copy() {
    final take = _source.length < _piece ? _source.length : _piece;
    if (_closed || take <= 0) {
      return false;
    }
    _output.writeBytes(_source.readBytes(take).toUint8List());
    return true;
  }

  bool _encode() {
    final take = _source.length < _piece ? _source.length : _piece;
    if (_closed || take <= 0) {
      return false;
    }
    final encoder = _startEncoder();
    final bytes = _source.readBytes(take).toUint8List();
    _data.crc32 = getCrc32(bytes, _data.crc32);
    _read += bytes.length;
    encoder.add(bytes);
    return true;
  }

  Sink<List<int>> _startEncoder() => _encoder ??= switch (_data.compression) {
        CompressionType.zstd => ZstdChunkedEncoder(ZLibOutputSink(_out),
            level: _data.level, contentSize: _source.length),
        CompressionType.xz => XzChunkedEncoder(ZLibOutputSink(_out)),
        _ => BZip2ChunkedEncoder(ZLibOutputSink(_out)),
      };

  /// Lets the entry go without finishing it. The archive is being abandoned,
  /// so we skip the descriptor and only release what the entry holds
  void cancel() {
    if (_closed) {
      return;
    }
    _closed = true;
    _sink?.close();
    _encoder = null;
    if (_data.deferred) {
      _source.reset();
    } else {
      _source.setPosition(_start);
    }
    _done();
  }

  /// Compresses what is left, then writes the crc and the sizes that the local
  /// header skipped. A copied entry has them in its local header
  void finish() {
    if (_closed) {
      return;
    }
    if (!_data.deferred) {
      _output.writeStream(_source);
      _closed = true;
      _source.setPosition(_start);
      _done();
      return;
    }
    final sink = _sink;
    if (_data.compression == CompressionType.none) {
      while (_store()) {}
    } else if (_data.compression != CompressionType.deflate) {
      _finishEncoder();
    } else if (sink == null) {
      final bytes = _source.toUint8List();
      _data.crc32 = getCrc32(bytes);
      _read = bytes.length;
      platformZLibEncoder.encodeStream(InputMemoryStream(bytes), _out,
          level: _data.level, raw: true);
    } else {
      while (step()) {}
      sink.close();
    }
    _aes?.finish();
    _closed = true;
    _source.reset();
    _data.compressedSize = _output.length - _before;
    _data.uncompressedSize = _read;
    _output
      ..writeUint32(ZipEncoder._dataDescriptorSignature)
      ..writeUint32(_data.crc32);
    if (_data.zip64) {
      _output
        ..writeUint64(_data.compressedSize)
        ..writeUint64(_data.uncompressedSize);
    } else {
      _output
        ..writeUint32(_data.compressedSize)
        ..writeUint32(_data.uncompressedSize);
    }
    _done();
  }

  void _finishEncoder() {
    final encoder = _encoder;
    if (encoder != null) {
      while (_encode()) {}
      encoder.close();
      return;
    }
    final source = _Crc32InputStream(_source);
    // ZstdChunkedEncoder was 4% slower on 100 MB and wrote other frames than
    // the buffered path on 10 MB, so an entry without steps keeps encodeStream
    switch (_data.compression) {
      case CompressionType.zstd:
        ZstdEncoder().encodeStream(source, _out, level: _data.level);
      case CompressionType.xz:
        XZEncoder().encodeStream(source, _out);
      default:
        BZip2Encoder().encodeStream(source, _out);
    }
    _data.crc32 = source.crc32;
    _read = source.count;
  }
}

/// Reads through another stream, keeping the CRC-32 and the count of the
/// bytes read, so that a compressor pulling its input through this one
/// produces the checksum of the entry in the same pass.
///
/// Bytes come back in memory streams, because a compressor asks for the bytes
/// of what it reads and that would otherwise read a file subset twice.
class _Crc32InputStream extends InputStream {
  final InputStream _input;
  int crc32 = 0;
  int count = 0;
  final _one = Uint8List(1);

  _Crc32InputStream(this._input) : super(byteOrder: _input.byteOrder);

  @override
  int get position => _input.position;

  @override
  set position(int v) => _input.position = v;

  @override
  int get length => _input.length;

  @override
  int get totalLength => _input.totalLength;

  @override
  bool get isEOS => _input.isEOS;

  @override
  bool open() => _input.open();

  @override
  Future<void> close() => _input.close();

  @override
  void closeSync() => _input.closeSync();

  @override
  void reset() => _input.reset();

  @override
  void setPosition(int v) => _input.setPosition(v);

  @override
  void rewind([int length = 1]) => _input.rewind(length);

  @override
  void skip(int length) => _input.skip(length);

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) =>
      _input.subset(position: position, length: length, bufferSize: bufferSize);

  @override
  int readByte() {
    final b = _input.readByte();
    _one[0] = b;
    crc32 = getCrc32(_one, crc32);
    count++;
    return b;
  }

  @override
  InputStream readBytes(int count) {
    final bytes = _input.readBytes(count).toUint8List();
    crc32 = getCrc32(bytes, crc32);
    this.count += bytes.length;
    return InputMemoryStream(bytes);
  }

  // The zstd encoder reads megabytes at a time into its window, and the
  // inherited readInto copied each read twice through readBytes: +29 MB peak
  // on a 300 MB entry
  @override
  int readInto(Uint8List into, int at, int count) {
    final got = _input.readInto(into, at, count);
    crc32 = getCrc32(Uint8List.sublistView(into, at, at + got), crc32);
    this.count += got;
    return got;
  }

  @override
  Uint8List toUint8List() {
    final bytes = _input.toUint8List();
    crc32 = getCrc32(bytes, crc32);
    count += bytes.length;
    return bytes;
  }
}

class _AesOutputStream extends OutputStream {
  final OutputStream _output;
  final Aes _aes;
  final _buffer = Uint8List(16 * 1024);
  var _held = 0;
  var _length = 0;

  _AesOutputStream(this._output, this._aes)
      : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _length;

  @override
  void writeByte(int value) {
    if (_held == _buffer.length) {
      _encrypt();
    }
    _buffer[_held++] = value;
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    var at = 0;
    while (at < count) {
      if (_held == _buffer.length) {
        _encrypt();
      }
      final n = min(count - at, _buffer.length - _held);
      _buffer.setRange(_held, _held + n, bytes, at);
      _held += n;
      at += n;
    }
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(
          stream.readBytes(min(_buffer.length, stream.length)).toUint8List());
    }
  }

  void _encrypt() {
    if (_held > 0) {
      _aes.processPart(_buffer, 0, _held);
      _output.writeBytes(_buffer, length: _held);
      _held = 0;
    }
  }

  /// Encrypts what is held and writes the authentication code after it
  void finish() {
    _encrypt();
    _aes.finishMac();
    _output.writeBytes(_aes.mac);
  }

  @override
  void flush() {}

  @override
  void clear() {
    _held = 0;
    _length = 0;
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('An encrypting stream keeps no bytes');
}

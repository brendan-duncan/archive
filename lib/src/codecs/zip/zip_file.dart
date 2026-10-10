import 'dart:math';
import 'dart:typed_data';

import '../../archive/compression_type.dart';
import '../../util/_limited_output_stream.dart';
import '../../util/aes.dart';
import '../../util/archive_exception.dart';
import '../../util/byte_order.dart';
import '../../util/crc32.dart';
import '../../util/encryption.dart';
import '../../util/file_content.dart';
import '../../util/input_decode_stream.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../bzip2_decoder.dart';
import '../zlib_decoder.dart';
import '../zstd_decoder.dart';
import 'zip_file_header.dart';

/// Internal class used by [ZipDecoder].
class ZipAesHeader {
  static const signature = 39169;

  int vendorVersion;
  String vendorId;
  int encryptionStrength; // 1: 128-bit, 2: 192-bit, 3: 256-bit
  int compressionMethod;

  ZipAesHeader(this.vendorVersion, this.vendorId, this.encryptionStrength,
      this.compressionMethod);
}

enum ZipEncryptionMode { none, zipCrypto, aes }

const _compressionTypes = <int, CompressionType>{
  0: CompressionType.none,
  8: CompressionType.deflate,
  12: CompressionType.bzip2,
  93: CompressionType.zstd,
};

/// A file object used by [ZipDecoder].
class ZipFile extends FileContent {
  static const zipSignature = 0x04034b50;
  static const zipCompressionStore = 0;
  static const zipCompressionDeflate = 8;
  static const zipCompressionBZip2 = 12;
  static const zipCompressionZstd = 93;
  static const zipCompressionAexEncryption = 99;

  int version = 0;
  int flags = 0;
  CompressionType compressionMethod = CompressionType.none;
  int lastModFileTime = 0;
  int lastModFileDate = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  String filename = '';
  Uint8List? extraField;
  ZipFileHeader? header;

  // Content of the file. If compressionMethod is not STORE, then it is
  // still compressed.
  InputStream? _rawContent;
  int? _computedCrc32;
  ZipEncryptionMode _encryptionType = ZipEncryptionMode.none;
  ZipAesHeader? _aesHeader;
  String? _password;

  ZipFile(this.header);

  @override
  bool get isCompressed =>
      _rawContent != null && compressionMethod != CompressionType.none;

  void read(InputStream input, {String? password}) {
    final sig = input.readUint32();
    if (sig != zipSignature) {
      return;
    }

    version = input.readUint16();
    flags = input.readUint16();
    final compression = input.readUint16();
    compressionMethod = _compressionTypes[compression] ?? CompressionType.none;
    lastModFileTime = input.readUint16();
    lastModFileDate = input.readUint16();
    crc32 = input.readUint32();
    compressedSize = input.readUint32();
    uncompressedSize = input.readUint32();
    final fnLen = input.readUint16();
    final exLen = input.readUint16();
    filename = input.readString(size: fnLen);
    extraField = input.readBytes(exLen).toUint8List();

    // Use the compressedSize and uncompressedSize from the CFD header.
    // For Zip64, the sizes in the local header will be 0xFFFFFFFF.
    compressedSize = header?.compressedSize ?? compressedSize;
    uncompressedSize = header?.uncompressedSize ?? uncompressedSize;

    _encryptionType = (flags & 0x1) != 0
        ? ZipEncryptionMode.zipCrypto
        : ZipEncryptionMode.none;

    _password = password;

    // Read compressedSize bytes for the compressed data.
    _rawContent = input.readBytes(header!.compressedSize);

    // A zip64 extra field in the local header decides the width of the sizes
    // in a data descriptor, so look for one before anything else.
    var localZip64 = false;
    if (exLen >= 4) {
      final extra = InputMemoryStream(extraField!);
      while (extra.length >= 4) {
        final id = extra.readUint16();
        final size = extra.readUint16();
        if (id == 1) {
          localZip64 = true;
        }
        extra.skip(size);
      }
    }

    if (_encryptionType != ZipEncryptionMode.none && exLen > 2) {
      final extra = InputMemoryStream(extraField!);
      while (!extra.isEOS) {
        final id = extra.readUint16();
        if (id == ZipAesHeader.signature) {
          extra.readUint16(); // dataSize = 7
          final vendorVersion = extra.readUint16();
          final vendorId = extra.readString(size: 2);
          final encryptionStrength = extra.readByte();
          final compressionMethod = extra.readUint16();

          _encryptionType = ZipEncryptionMode.aes;
          _aesHeader = ZipAesHeader(
              vendorVersion, vendorId, encryptionStrength, compressionMethod);

          // compressionMethod in the file header will be 99 for aes encrypted
          // files. The compressionMethod value in the AES extraField stores the
          // actual compressionMethod.
          this.compressionMethod =
              _compressionTypes[_aesHeader!.compressionMethod] ??
                  CompressionType.none;
        }
      }
    }

    // If bit 3 (0x08) of the flags field is set, then the CRC-32 and file
    // sizes are not known when the header is written. The fields in the
    // local header are filled with zero, and the CRC-32 and size are
    // appended in a 12-byte structure (optionally preceded by a 4-byte
    // signature) immediately after the compressed data:
    // The sizes are 8 bytes when the local header has a zip64 extra field
    // (APPNOTE 4.3.9.2), which is what a streaming writer puts there for an
    // entry that may grow past 4 GB.
    if (flags & 0x08 != 0) {
      final sigOrCrc = input.readUint32();
      if (sigOrCrc == 0x08074b50) {
        crc32 = input.readUint32();
      } else {
        crc32 = sigOrCrc;
      }

      final descCompressedSize =
          localZip64 ? input.readUint64() : input.readUint32();
      final descUncompressedSize =
          localZip64 ? input.readUint64() : input.readUint32();
      // The central directory already supplied the sizes, and is the
      // reliable place for them: the descriptor is only consulted without it.
      if (header == null) {
        compressedSize = descCompressedSize;
        uncompressedSize = descUncompressedSize;
      }
    }
  }

  /// This will decompress the data (if necessary) in order to calculate the
  /// crc32 checksum for the decompressed data and verify it with the value
  /// stored in the zip.
  bool verifyCrc32() {
    if (_computedCrc32 == null) {
      // Summed as it is decompressed, so that an entry of any size can be
      // checked without being held in memory.
      final sum = _Crc32OutputStream();
      decompress(sum);
      _computedCrc32 = sum.crc32;
    }
    return _computedCrc32 == crc32;
  }

  // The content as it is stored in the zip, decrypted if it is encrypted. A
  // new stream each time, decrypting as it is read, so that nothing is held
  // in memory and the content can be read again.
  InputStream _storedContent() {
    final raw = _rawContent!;
    if (_encryptionType == ZipEncryptionMode.none || raw.length <= 0) {
      return raw;
    }
    final password = _password;
    if (password == null) {
      throw ArchiveException('A password is needed for the encrypted entry '
          '$filename');
    }
    if (_encryptionType == ZipEncryptionMode.zipCrypto) {
      // The last byte of the encryption header is the high byte of the CRC,
      // or of the modification time when the CRC was not known at the time
      // of writing, which is the only check there is on the password.
      final check =
          flags & 0x08 != 0 ? (lastModFileTime >> 8) & 0xff : crc32 >>> 24;
      // As a view of known length, since a decompressor asks the length of
      // its input and the stream itself can only answer by decrypting it all.
      return InputDecodeStream(_ZipCryptoDecoder(raw.subset(), password, check))
          .readBytes(max(0, raw.length - 12));
    }
    final aes = _aesHeader!;
    final saltLength = _AesDecoder.saltLength(aes);
    return InputDecodeStream(_AesDecoder(raw.subset(), aes, password))
        .readBytes(max(0, raw.length - saltLength - 2 - 10));
  }

  @override
  void decompress(OutputStream output) {
    if (_rawContent == null) {
      return;
    }

    final content = _storedContent();
    final savePos = content.position;
    // The archive says how large the entry is, which is what a caller can
    // check before reading it, so the data is not let decode past that.
    try {
      decodeLimited(output, uncompressedSize, (output) {
        switch (compressionMethod) {
          case CompressionType.deflate:
            ZLibDecoder().decodeStream(content, output, raw: true);
          case CompressionType.bzip2:
            BZip2Decoder().decodeStream(content, output);
          case CompressionType.zstd:
            ZstdDecoder().decodeStream(content, output);
          case CompressionType.none:
            output.writeStream(content);
        }
        return true;
      });
    } finally {
      content.setPosition(savePos);
    }
  }

  @override
  int get length => _rawContent?.length ?? 0;

  /// Get the decompressed content from the file. The file isn't decompressed
  /// until it is requested.
  @override
  InputStream getStream({bool decompress = true}) {
    if (_rawContent == null) {
      return InputMemoryStream(Uint8List(0));
    }
    final content = _storedContent();
    if (!decompress) {
      return content;
    }

    const maxDecodeBufferSize = 500 * 1024 * 1024; // 500MB

    final savePos = content.position;
    final Uint8List bytes;
    if (compressionMethod == CompressionType.none) {
      bytes = content.toUint8List();
    } else {
      // [uncompressedSize] comes from the archive, so a crafted value is not
      // trusted to size an allocation: the stream grows into what the data
      // needs. It does bound that growth, as in [decompress].
      final output = OutputMemoryStream(
          size: uncompressedSize > 0 && uncompressedSize <= maxDecodeBufferSize
              ? uncompressedSize
              : null);
      this.decompress(output);
      bytes = output.getBytes();
    }
    content.setPosition(savePos);
    return InputMemoryStream(bytes);
  }

  /// The content as stored in the zip: compressed, and encrypted if it was.
  Uint8List getRawContent() {
    if (_rawContent == null) {
      return Uint8List(0);
    }
    return _rawContent!.toUint8List();
  }

  @override
  String toString() => filename;

  static Uint8List deriveKey(String password, Uint8List salt,
      {int derivedKeyLength = 32}) {
    if (password.isEmpty) {
      return Uint8List(0);
    }
    final passwordBytes = Uint8List.fromList(password.codeUnits);
    const iterationCount = 1000;
    final totalSize = (derivedKeyLength * 2) + 2;

    final params = PcPbkdf2Parameters(salt, iterationCount, totalSize);
    final keyDerivator = PcPBKDF2KeyDerivator(PcHMac(PcSHA1Digest(), 64));

    keyDerivator.init(params);
    return keyDerivator.process(passwordBytes);
  }

  @override
  Future<void> close() async {
    await _rawContent?.close();
  }

  @override
  void closeSync() {
    _rawContent?.closeSync();
  }

  @override
  void write(OutputStream output) => output.writeStream(getStream());
}

/// Decrypts traditional PKWARE encryption as it is read.
class _ZipCryptoDecoder implements ChunkDecoder {
  final InputStream _input;
  // The three key registers, kept as 32-bit values.
  int _k0 = 305419896;
  int _k1 = 591751049;
  int _k2 = 878082192;
  final int _check;
  bool _started = false;

  static const _chunkSize = 64 * 1024;

  _ZipCryptoDecoder(this._input, String password, this._check) {
    for (final c in password.codeUnits) {
      _update(c);
    }
  }

  @override
  int get history => 0;

  // A 32-bit multiply that is exact on the web too, where an int is a double
  // and the full product would lose its low bits.
  static int _mul32(int a, int b) =>
      ((a & 0xffff) * b + ((((a >>> 16) * b) & 0xffff) << 16)) & 0xffffffff;

  void _update(int c) {
    _k0 = getCrc32Byte(_k0, c);
    _k1 = (_k1 + (_k0 & 0xff)) & 0xffffffff;
    _k1 = (_mul32(_k1, 134775813) + 1) & 0xffffffff;
    _k2 = getCrc32Byte(_k2, _k1 >>> 24);
  }

  int _decode(int c) {
    final temp = (_k2 & 0xffff) | 2;
    c ^= ((temp * (temp ^ 1)) >> 8) & 0xff;
    _update(c);
    return c;
  }

  @override
  bool decodeChunk(OutputStream output) {
    if (!_started) {
      _started = true;
      // The 12 byte encryption header feeds the keys, and its last byte
      // is the password check.
      if (_input.length < 12) {
        throw ArchiveException('Truncated encrypted entry');
      }
      var last = 0;
      for (var i = 0; i < 12; ++i) {
        last = _decode(_input.readByte());
      }
      if (last != _check) {
        throw ArchiveException('Wrong password for the encrypted entry');
      }
    }
    if (_input.isEOS) {
      return false;
    }
    final encrypted =
        _input.readBytes(min(_chunkSize, _input.length)).toUint8List();
    // Into a buffer of its own: the bytes read may be a view of the archive.
    final bytes = Uint8List(encrypted.length);
    for (var i = 0; i < bytes.length; ++i) {
      bytes[i] = _decode(encrypted[i]);
    }
    output.writeBytes(bytes);
    return true;
  }
}

/// Decrypts WinZip AES encryption as it is read, checking the password
/// before the first byte and the authentication code after the last.
class _AesDecoder implements ChunkDecoder {
  final InputStream _input;
  final ZipAesHeader _header;
  final String _password;
  Aes? _aes;
  int _remaining = 0;
  bool _done = false;

  static const _chunkSize = 64 * 1024;

  _AesDecoder(this._input, this._header, this._password);

  /// The salt is half the key size: 8, 12 or 16 bytes for 128, 192 or
  /// 256-bit keys.
  static int saltLength(ZipAesHeader header) =>
      switch (header.encryptionStrength) { 1 => 8, 2 => 12, _ => 16 };

  @override
  int get history => 0;

  @override
  bool decodeChunk(OutputStream output) {
    if (_done) {
      return false;
    }
    var aes = _aes;
    if (aes == null) {
      final saltLength = _AesDecoder.saltLength(_header);
      final keySize = saltLength * 2;
      if (_input.length < saltLength + 2 + 10) {
        throw ArchiveException('Truncated encrypted entry');
      }
      final salt = _input.readBytes(saltLength).toUint8List();
      final verify = _input.readBytes(2).toUint8List();

      final derivedKey =
          ZipFile.deriveKey(_password, salt, derivedKeyLength: keySize);
      final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
      final hmacKeyData =
          Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));
      final pwdCheck = derivedKey.sublist(keySize * 2, keySize * 2 + 2);
      if (!Uint8ListEquality.equals(pwdCheck, verify)) {
        throw ArchiveException('Wrong password for the encrypted entry');
      }

      aes = _aes = Aes(keyData, hmacKeyData, keySize);
      _remaining = _input.length - 10;
    }

    if (_remaining > 0) {
      final n = min(_chunkSize, _remaining);
      // A copy, as the cipher works in place and the bytes read may be a
      // view of the archive.
      final bytes = Uint8List.fromList(_input.readBytes(n).toUint8List());
      aes.update(bytes, 0, bytes.length);
      output.writeBytes(bytes);
      _remaining -= n;
      return true;
    }

    final mac = _input.readBytes(10).toUint8List();
    _done = true;
    if (!Uint8ListEquality.equals(mac, aes.finish())) {
      throw ArchiveException(
          'The authentication code of the encrypted entry does not match');
    }
    return false;
  }
}

/// Sums the CRC-32 of what is written to it.
class _Crc32OutputStream extends OutputStream {
  int crc32 = 0;
  int _length = 0;

  _Crc32OutputStream() : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _length;

  @override
  void writeByte(int value) {
    crc32 = getCrc32Byte(crc32 ^ 0xffffffff, value) ^ 0xffffffff;
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    crc32 = getCrc32(
        length == bytes.length
            ? bytes
            : bytes is Uint8List
                ? Uint8List.sublistView(bytes, 0, length)
                : bytes.sublist(0, length),
        crc32);
    _length += length;
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final bytes = stream.readBytes(min(65536, stream.length)).toUint8List();
      if (bytes.isEmpty) {
        break;
      }
      writeBytes(bytes);
    }
  }

  @override
  void flush() {}

  @override
  void clear() {}

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('A checksum stream cannot be read back');
}

import '../bzip2_decoder.dart';
import '../util/aes.dart';
import '../util/archive_exception.dart';
import '../util/crc32.dart';
import '../util/input_stream.dart';
import '../util/output_stream.dart';
import '../util/_file_content.dart';
import '../zlib/inflate.dart';
import '../zlib/inflate_buffer.dart';
import 'zip_file_header.dart';
import 'dart:typed_data';
import "package:pointycastle/export.dart";

class AesHeader {
  static const signature = 39169;

  int vendorVersion;
  String vendorId;
  int encryptionStrength; // 1: 128-bit, 2: 192-bit, 3: 256-bit
  int compressionMethod;

  AesHeader(this.vendorVersion, this.vendorId, this.encryptionStrength,
      this.compressionMethod);
}

class ZipFile extends FileContent {
  static const int zipCompressionStore = 0;
  static const int zipCompressionDeflate = 8;
  static const int zipCompressionBZip2 = 12;
  static const int zipCompressionAexEncryption = 99;

  static const int zipFileSignature = 0x04034b50;

  int signature = zipFileSignature; // 4 bytes
  int version = 0; // 2 bytes
  int flags = 0; // 2 bytes
  int compressionMethod = 0; // 2 bytes
  int lastModFileTime = 0; // 2 bytes
  int lastModFileDate = 0; // 2 bytes
  int? crc32; // 4 bytes
  int? compressedSize; // 4 bytes
  int? uncompressedSize; // 4 bytes
  String filename = ''; // 2 bytes length, n-bytes data
  List<int> extraField = []; // 2 bytes length, n-bytes data
  ZipFileHeader? header;

  ZipFile([InputStreamBase? input, this.header, String? password]) {
    if (input != null) {
      signature = input.readUint32();
      if (signature != zipFileSignature) {
        throw ArchiveException('Invalid Zip Signature');
      }

      version = input.readUint16();
      flags = input.readUint16();
      compressionMethod = input.readUint16();
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

      _encryptionType =
          (flags & 0x1) != 0 ? encryptionZipCrypto : encryptionNone;
      _password = password;

      // Read compressedSize bytes for the compressed data.
      _rawContent = input.readBytes(header!.compressedSize!);

      if (_encryptionType != 0 && exLen > 2) {
        final extra = InputStream(extraField);
        while (!extra.isEOS) {
          final id = extra.readUint16();
          final size = extra.readUint16();
          final extraBytes = extra.readBytes(size);
          if (id == AesHeader.signature) {
            final vendorVersion = extraBytes.readUint16();
            final vendorId = extraBytes.readString(size: 2);
            final encryptionStrength = extraBytes.readByte();
            final compressionMethod = extraBytes.readUint16();

            _encryptionType = encryptionAes;
            _aesHeader = AesHeader(
                vendorVersion, vendorId, encryptionStrength, compressionMethod);

            // compressionMethod in the file header will be 99 for aes encrypted
            // files. The compressionMethod value in the AES extraField stores
            // the actual compressionMethod.
            this.compressionMethod = _aesHeader!.compressionMethod;
          }
        }
      }

      if (_encryptionType == 1 && password != null) {
        _initKeys(password);
      }

      // If bit 3 (0x08) of the flags field is set, then the CRC-32 and file
      // sizes are not known when the header is written. The fields in the
      // local header are filled with zero, and the CRC-32 and size are
      // appended in a 12-byte structure (optionally preceded by a 4-byte
      // signature) immediately after the compressed data:
      if (flags & 0x08 != 0) {
        final sigOrCrc = input.readUint32();
        if (sigOrCrc == 0x08074b50) {
          crc32 = input.readUint32();
        } else {
          crc32 = sigOrCrc;
        }

        compressedSize = input.readUint32();
        uncompressedSize = input.readUint32();
      }
    }

    // Make sure to use the Central Directory filename to avoid filename
    // spoofing. https://github.com/brendan-duncan/archive/issues/266
    filename = header?.filename ?? filename;
  }

  /// This will decompress the data (if necessary) in order to calculate the
  /// crc32 checksum for the decompressed data and verify it with the value
  /// stored in the zip.
  bool verifyCrc32() {
    _computedCrc32 ??= getCrc32(content);
    return _computedCrc32 == crc32;
  }

  /// Get the decompressed content from the file. The file isn't decompressed
  /// until it is requested.
  @override
  List<int> get content {
    if (_content == null) {
      if (_encryptionType != encryptionNone) {
        if (_rawContent.length <= 0) {
          _content = _rawContent.toUint8List();
          _encryptionType = encryptionNone;
        } else {
          if (_encryptionType == encryptionZipCrypto) {
            _rawContent = _decodeZipCrypto(_rawContent);
          } else if (_encryptionType == encryptionAes) {
            _rawContent = _decodeAes(_rawContent);
          }
          _encryptionType = encryptionNone;
        }
      }

      if (compressionMethod == zipCompressionDeflate) {
        const oneGB = 1024 * 1024 * 1024;
        if (_rawContent is InputStream ||
            (useNativeZLib() && _rawContent.length < oneGB)) {
          _content = inflateBuffer(_rawContent.toUint8List());
        } else {
          _content = Inflate.buffer(_rawContent, uncompressedSize).getBytes();
        }
        compressionMethod = zipCompressionStore;
      } else if (compressionMethod == zipCompressionBZip2) {
        final output = OutputStream();
        BZip2Decoder().decodeStream(_rawContent, output);
        _content = output.getBytes();
        compressionMethod = zipCompressionStore;
      } else if (compressionMethod == zipCompressionStore) {
        _content = _rawContent.toUint8List();
      } else {
        throw ArchiveException(
            'Unsupported zip compression method $compressionMethod');
      }
    }

    return _content!;
  }

  dynamic get rawContent {
    if (_content != null) {
      return _content;
    }
    return _rawContent;
  }

  @override
  String toString() => filename;

  void _initKeys(String password) {
    _keys[0] = 305419896;
    _keys[1] = 591751049;
    _keys[2] = 878082192;
    for (final c in password.codeUnits) {
      _updateKeys(c);
    }
  }

  void _updateKeys(int c) {
    _keys[0] = CRC32(_keys[0], c);
    _keys[1] += _keys[0] & 0xff;
    _keys[1] = _keys[1] * 134775813 + 1;
    _keys[2] = CRC32(_keys[2], (_keys[1] >> 24) & 0xff);
  }

  int _decryptByte() {
    final temp = (_keys[2] & 0xffff) | 2;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  void _decodeByte(int c) {
    c ^= _decryptByte();
    _updateKeys(c);
  }

  InputStream _decodeZipCrypto(InputStreamBase input) {
    for (var i = 0; i < 12; ++i) {
      _decodeByte(_rawContent.readByte());
    }
    final bytes = _rawContent.toUint8List();
    for (var i = 0; i < bytes.length; ++i) {
      final temp = bytes[i] ^ _decryptByte();
      _updateKeys(temp);
      bytes[i] = temp;
    }
    return InputStream(bytes);
  }

  InputStream _decodeAes(InputStreamBase input) {
    Uint8List salt;
    int keySize = 16;
    if (_aesHeader!.encryptionStrength == 1) {
      // 128-bit
      salt = input.readBytes(8).toUint8List();
      keySize = 16;
    } else if (_aesHeader!.encryptionStrength == 2) {
      // 192-bit
      salt = input.readBytes(12).toUint8List();
      keySize = 24;
    } else {
      // 256-bit
      salt = input.readBytes(16).toUint8List();
      keySize = 32;
    }

    var verify = input.readBytes(2).toUint8List();
    final dataBytes = input.readBytes(input.length - 10);
    final dataMac = input.readBytes(10);
    final bytes = dataBytes.toUint8List();

    var derivedKey = deriveKey(_password!, salt, derivedKeyLength: keySize);
    final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
    final hmacKeyData =
        Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));
    // var authCode = deriveKey.sublist(keySize, keySize*2);
    var pwdCheck = derivedKey.sublist(keySize * 2, keySize * 2 + 2);
    if (!Uint8ListEquality.equals(pwdCheck, verify)) {
      throw Exception('password error');
    }

    Aes aes = Aes(keyData, hmacKeyData, keySize);
    aes.processData(bytes, 0, bytes.length);
    if (!Uint8ListEquality.equals(dataMac.toUint8List(), aes.mac)) {
      throw Exception('macs don\'t match');
    }
    return InputStream(bytes);
  }

  static Uint8List deriveKey(String password, Uint8List salt,
      {int derivedKeyLength = 32}) {
    if (password.isEmpty) {
      return Uint8List(0);
    }
    final passwordBytes = Uint8List.fromList(password.codeUnits);
    const iterationCount = 1000;
    int totalSize = (derivedKeyLength * 2) + 2;
    final params = Pbkdf2Parameters(salt, iterationCount, totalSize);
    final keyDerivator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64));
    keyDerivator.init(params);
    return keyDerivator.process(passwordBytes);
  }

  static const encryptionNone = 0;
  static const encryptionZipCrypto = 1;
  static const encryptionAes = 2;

  // Content of the file. If compressionMethod is not STORE, then it is
  // still compressed.
  late InputStreamBase _rawContent;
  List<int>? _content;
  int? _computedCrc32;
  int _encryptionType = encryptionNone;
  AesHeader? _aesHeader;
  String? _password;

  final _keys = <int>[0, 0, 0];
}

import 'dart:typed_data';

import "package:pointycastle/export.dart";

import '../../archive/compression_type.dart';
import '../../util/aes_decrypt.dart';
import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
import '../../util/file_content.dart';
import '../../util/input_stream.dart';
import '../../util/input_stream_memory.dart';
import '../../util/output_stream.dart';
import '../zlib/inflate.dart';
import 'zip_file_header.dart';

class AesHeader {
  static const signature = 39169;

  int vendorVersion;
  String vendorId;
  int encryptionStrength; // 1: 128-bit, 2: 192-bit, 3: 256-bit
  int compressionMethod;

  AesHeader(this.vendorVersion, this.vendorId, this.encryptionStrength,
      this.compressionMethod);
}

enum EncryptionMode { none, zipCrypto, aes }

const _compressionTypes = <int, CompressionType>{
  0: CompressionType.none,
  8: CompressionType.deflate,
  12: CompressionType.bzip2
};

class ZipFile extends FileContent {
  static const int zipSignature = 0x04034b50;

  int version = 0;
  int flags = 0;
  CompressionType compressionMethod = CompressionType.none;
  int lastModFileTime = 0;
  int lastModFileDate = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  String filename = '';
  late Uint8List extraField;
  ZipFileHeader? header;

  // Content of the file. If compressionMethod is not STORE, then it is
  // still compressed.
  late InputStream _rawContent;
  Uint8List? _content;
  int? _computedCrc32;
  EncryptionMode _encryptionType = EncryptionMode.none;
  AesHeader? _aesHeader;
  String? _password;

  final _keys = <int>[0, 0, 0];

  ZipFile(this.header);

  void read(InputStream input, {String? password}) {
    final sig = input.readUint32();
    if (sig != zipSignature) {
      throw ArchiveException('Invalid Zip Signature');
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

    _encryptionType =
        (flags & 0x1) != 0 ? EncryptionMode.zipCrypto : EncryptionMode.none;

    _password = password;

    // Read compressedSize bytes for the compressed data.
    _rawContent = input.readBytes(header!.compressedSize);

    if (_encryptionType != EncryptionMode.none && exLen > 2) {
      final extra = InputStreamMemory(extraField);
      final id = extra.readUint16();
      if (id == AesHeader.signature) {
        extra.readUint16(); // dataSize = 7
        final vendorVersion = extra.readUint16();
        final vendorId = extra.readString(size: 2);
        final encryptionStrength = extra.readByte();
        final compressionMethod = extra.readUint16();

        _encryptionType = EncryptionMode.aes;
        _aesHeader = AesHeader(
            vendorVersion, vendorId, encryptionStrength, compressionMethod);

        // compressionMethod in the file header will be 99 for aes encrypted
        // files. The compressionMethod value in the AES extraField stores the
        // actual compressionMethod.
        this.compressionMethod =
            _compressionTypes[_aesHeader!.compressionMethod] ??
                CompressionType.none;
      }
    } else if (_encryptionType == EncryptionMode.zipCrypto &&
        password != null) {
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

  /// This will decompress the data (if necessary) in order to calculate the
  /// crc32 checksum for the decompressed data and verify it with the value
  /// stored in the zip.
  bool verifyCrc32() {
    final contentStream = getStream();
    _computedCrc32 ??= getCrc32List(contentStream.toUint8List());
    return _computedCrc32 == crc32;
  }

  @override
  void decompress(OutputStream output) {
    if (_encryptionType != EncryptionMode.none) {
      if (_rawContent.length <= 0) {
        _content = _rawContent.toUint8List();
        _encryptionType = EncryptionMode.none;
      } else {
        if (_encryptionType == EncryptionMode.zipCrypto) {
          _rawContent = _decodeZipCrypto(_rawContent);
        } else if (_encryptionType == EncryptionMode.aes) {
          _rawContent = _decodeAes(_rawContent);
        }
        _encryptionType = EncryptionMode.none;
      }
    }

    Inflate.stream(_rawContent,
        uncompressedSize: uncompressedSize, output: output)
    .inflate();
  }

  /// Get the decompressed content from the file. The file isn't decompressed
  /// until it is requested.
  @override
  InputStream getStream() {
    if (_content == null) {
      if (_encryptionType != EncryptionMode.none) {
        if (_rawContent.length <= 0) {
          _content = _rawContent.toUint8List();
          _encryptionType = EncryptionMode.none;
        } else {
          if (_encryptionType == EncryptionMode.zipCrypto) {
            _rawContent = _decodeZipCrypto(_rawContent);
          } else if (_encryptionType == EncryptionMode.aes) {
            _rawContent = _decodeAes(_rawContent);
          }
          _encryptionType = EncryptionMode.none;
        }
      }

      if (compressionMethod == CompressionType.deflate) {
        final decompress =
            Inflate.stream(_rawContent, uncompressedSize: uncompressedSize)
              ..inflate();
        _content = decompress.getBytes();
        compressionMethod = CompressionType.none;
      } else {
        _content = _rawContent.toUint8List();
      }
    }

    return InputStreamMemory(_content!);
  }

  Uint8List getRawContent() {
    if (_content != null) {
      return _content!;
    }
    return _rawContent.toUint8List();
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
    _keys[0] = getCrc32Byte(_keys[0], c);
    _keys[1] += _keys[0] & 0xff;
    _keys[1] = _keys[1] * 134775813 + 1;
    _keys[2] = getCrc32Byte(_keys[2], _keys[1] >> 24);
  }

  int _decryptByte() {
    final temp = (_keys[2] & 0xffff) | 2;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  void _decodeByte(int c) {
    c ^= _decryptByte();
    _updateKeys(c);
  }

  InputStream _decodeZipCrypto(InputStream input) {
    for (var i = 0; i < 12; ++i) {
      _decodeByte(_rawContent.readByte());
    }
    final bytes = _rawContent.toUint8List();
    for (var i = 0; i < bytes.length; ++i) {
      final temp = bytes[i] ^ _decryptByte();
      _updateKeys(temp);
      bytes[i] = temp;
    }
    return InputStreamMemory(bytes);
  }

  InputStream _decodeAes(InputStream input) {
    Uint8List salt;
    if (_aesHeader!.encryptionStrength == 1) {
      // 128-bit
      salt = input.readBytes(8).toUint8List();
    } else if (_aesHeader!.encryptionStrength == 1) {
      // 192-bit
      salt = input.readBytes(12).toUint8List();
    } else {
      // 256-bit
      salt = input.readBytes(16).toUint8List();
    }

    //int verification = input.readUint16();
    final dataBytes = input.readBytes(input.length - 10);
    final bytes = dataBytes.toUint8List();

    final key = _deriveKey(_password!, salt);

    AesDecrypt(key).decryptCrt(bytes);

    return InputStreamMemory(bytes);
  }

  static Uint8List _deriveKey(String password, Uint8List salt,
      {int derivedKeyLength = 32}) {
    if (password.isEmpty) {
      return Uint8List(0);
    }

    final passwordBytes = Uint8List.fromList(password.codeUnits);

    const iterationCount = 1000;
    final params = Pbkdf2Parameters(salt, iterationCount, derivedKeyLength);
    final keyDerivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(params);

    return keyDerivator.process(passwordBytes);
  }

  @override
  void close() {
    _content = null;
  }

  @override
  void write(OutputStream output) => output.writeStream(getStream());
}

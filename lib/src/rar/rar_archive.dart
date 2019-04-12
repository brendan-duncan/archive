import 'rar_entry.dart';
import '../util/archive_exception.dart';
import '../util/input_stream.dart';

enum RarVersion {
  none,
  rar14,
  rar15,
  rar50,
  future
}

class RarHeader {
  // RAR 5.0 Header Types
  static const HEAD_MARK = 0;
  static const HEAD_MAIN = 1;
  static const HEAD_FILE = 2;
  static const HEAD_SERVICE = 3;
  static const HEAD_CRYPT = 4;
  static const HEAD_ENDARC = 5;
  static const HEAD_UNKNOWN = 0xff;
  // RAR 1.5 - 4.x Header Types
  static const HEAD3_MARK = 0x72;
  static const HEAD3_MAIN = 0x73;
  static const HEAD3_FILE = 0x74;
  static const HEAD3_CMT = 0x75;
  static const HEAD3_AV = 0x76;
  static const HEAD3_OLDSERVICE = 0x77;
  static const HEAD3_PROTECT = 0x78;
  static const HEAD3_SIGN = 0x79;
  static const HEAD3_SERVICE = 0x7a;
  static const HEAD3_ENDARC = 0x7b;

  int crc;
  int type;
  int flags;
  int size;

  RarHeader([this.crc = 0, this.type = HEAD_UNKNOWN,
             this.flags = 0, this.size = 0]);
}


class RarArchive {
  List<RarEntry> entries = [];
  RarVersion version = RarVersion.none;

  RarArchive(InputStreamBase input) {
    version = _readSignature(input);
    if (version == RarVersion.none) {
      throw ArchiveException("Invalid archive");
    }

    var mainHeader = _readHeader(input);
    if (mainHeader.type != RarHeader.HEAD_MAIN) {
      throw ArchiveException("Invalid archive");
    }

    while (!input.isEOS) {
      var entryHeader = _readHeader(input);
      if ((entryHeader.flags & 0x8000) != 0) {
        entryHeader.size += input.readUint32();
      }

      if (entryHeader.type == RarHeader.HEAD_FILE) {
        var entry = input.readBytes(entryHeader.size);
      } else {
        input.skip(entryHeader.size);
      }
    }
  }

  RarHeader _readHeader(InputStreamBase input) {
    switch (version) {
      case RarVersion.rar14:
        return _readHeader14(input);
      case RarVersion.rar15:
        return _readHeader15(input);
      case RarVersion.rar50:
        return _readHeader50(input);
      case RarVersion.none:
      case RarVersion.future:
        return RarHeader();
    }
  }

  RarHeader _readHeader14(InputStreamBase input) {
    return RarHeader();
  }

  RarHeader _readHeader15(InputStreamBase input) {
    var raw = input.readBytes(7);
    var crc = raw.readUint16();
    var type = raw.readByte();
    var flags = raw.readUint16();
    var size = raw.readUint16();

    switch (type) {
      case RarHeader.HEAD3_MAIN:
        type = RarHeader.HEAD_MAIN;
        break;
      case RarHeader.HEAD3_FILE:
        type = RarHeader.HEAD_FILE;
        break;
      case RarHeader.HEAD3_SERVICE:
        type = RarHeader.HEAD_SERVICE;
        break;
      case RarHeader.HEAD3_ENDARC:
        type = RarHeader.HEAD_ENDARC;
        break;
    }

    input.skip(size - 7);

    return RarHeader(crc, type, flags, size);
  }

  RarHeader _readHeader50(InputStreamBase input) {
    return RarHeader();
  }

  RarVersion _readSignature(InputStreamBase input) {
    var signature = input.readBytes(7).toUint8List();
    if (signature.length != 7 || signature[0] != 0x52) {
      return RarVersion.none;
    }
    if (signature[1] == 0x45 && signature[2] == 0x7e && signature[3] == 0x5e) {
      return RarVersion.rar14;
    }
    if (signature[1] == 0x61 && signature[2] == 0x72 && signature[3] == 0x21 &&
        signature[4] == 0x1a && signature[5] == 0x07) {
      if (signature[6] == 0x00) {
        return RarVersion.rar15;
      }
      if (signature[6] == 0x01) {
        input.skip(1); // RAR 5 signature is 8 bytes
        return RarVersion.rar50;
      }
      if (signature[6] > 1 &&signature[6] < 5) {
        return RarVersion.future;
      }
    }
    return RarVersion.none;
  }

  int _readVInt(InputStreamBase input) {
    int result = 0;
    for (int shift = 0; !input.isEOS && shift < 64; shift += 7) {
      var curByte = input.readByte();
      result += (curByte & 0x7f) << shift;
      if ((curByte & 0x80) == 0) {
        return result;
      }
    }
    // out of buffer border
    return 0;
  }
}
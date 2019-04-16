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

class Rar {
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

  static const MHD_VOLUME = 0x0001;
  // Old style main archive comment embed into main archive header. Must not
  // be used in new archives anymore.
  static const MHD_COMMENT = 0x0002;

  static const MHD_LOCK = 0x0004;
  static const MHD_SOLID = 0x0008;
  static const MHD_PACK_COMMENT = 0x0010;
  static const MHD_NEWNUMBERING = 0x0010;
  static const MHD_AV = 0x0020;
  static const MHD_PROTECT = 0x0040;
  static const MHD_PASSWORD = 0x0080;
  static const MHD_FIRSTVOLUME = 0x0100;

  static const LHD_SPLIT_BEFORE = 0x0001;
  static const LHD_SPLIT_AFTER = 0x0002;
  static const LHD_PASSWORD = 0x0004;

  // Old style file comment embed into file header. Must not be used
  // in new archives anymore.
  static const LHD_COMMENT = 0x0008;

  // For non-file subheaders it denotes 'subblock having a parent file' flag.
  static const LHD_SOLID = 0x0010;

  static const LHD_WINDOWMASK = 0x00e0;
  static const LHD_WINDOW64 = 0x0000;
  static const LHD_WINDOW128 = 0x0020;
  static const LHD_WINDOW256 = 0x0040;
  static const LHD_WINDOW512 = 0x0060;
  static const LHD_WINDOW1024 = 0x0080;
  static const LHD_WINDOW2048 = 0x00a0;
  static const LHD_WINDOW4096 = 0x00c0;
  static const LHD_DIRECTORY = 0x00e0;

  static const LHD_LARGE = 0x0100;
  static const LHD_UNICODE = 0x0200;
  static const LHD_SALT = 0x0400;
  static const LHD_VERSION = 0x0800;
  static const LHD_EXTTIME = 0x1000;

  static const SKIP_IF_UNKNOWN = 0x4000;
  static const LONG_BLOCK = 0x8000;

  static const EARC_NEXT_VOLUME = 0x0001; // Not last volume.
  static const EARC_DATACRC = 0x0002; // Store CRC32 of RAR archive (now is used only in volumes).
  static const EARC_REVSPACE = 0x0004; // Reserve space for end of REV file 7 byte record.
  static const EARC_VOLNUMBER = 0x0008;

  // Internal implementation, depends on archive format version.
  // RAR 5.0 host OS
  static const HOST5_WINDOWS = 0;
  static const HOST5_UNIX = 1;
  // RAR 3.0 host OS.
  static const HOST_MSDOS = 0;
  static const HOST_OS2 = 1;
  static const HOST_WIN32 = 2;
  static const HOST_UNIX = 3;
  static const HOST_MACOS = 4;
  static const HOST_BEOS = 5;
  static const HOST_MAX = 6;

  // Crypt Method
  static const CRYPT_NONE = 0;
  static const CRYPT_RAR13 = 1;
  static const CRYPT_RAR15 = 2;
  static const CRYPT_RAR20 = 3;
  static const CRYPT_RAR30 = 4;
  static const CRYPT_RAR50 = 5;

  // Unified archive format independent implementation.
  static const HSYS_WINDOWS = 0;
  static const HSYS_UNIX = 1;
  static const HSYS_UNKNOWN = 2;
}

class RarHeader {
  int crc;
  int type;
  int flags;
  int size;

  RarHeader([this.crc = 0, this.type = Rar.HEAD_UNKNOWN,
             this.flags = 0, this.size = 0]);
}

class RarMainHeader extends RarHeader {
  bool volume;
  bool solid;
  bool locked;
  bool protected;
  bool encrypted;
  bool signed;
  bool commentInHeader;
  bool firstVolume;
  bool newNumbering;
  int highPosAV = 0;
  int posAV = 0;

  RarMainHeader(int crc, int flags, int size)
    : super(crc, Rar.HEAD_MAIN, flags, size) {
    volume = (flags & Rar.MHD_VOLUME) != 0;
    solid = (flags & Rar.MHD_SOLID) != 0;
    locked = (flags & Rar.MHD_LOCK) != 0;
    protected = (flags & Rar.MHD_PROTECT) != 0;
    encrypted = (flags & Rar.MHD_PASSWORD) != 0;
    signed = false;//posAV != 0 || highPosAV != 0;
    commentInHeader = (flags & Rar.MHD_COMMENT) != 0;
    firstVolume = (flags & Rar.MHD_FIRSTVOLUME) != 0;
    newNumbering = (flags & Rar.MHD_NEWNUMBERING) != 0;
  }
}

class RarFileHeader extends RarHeader {
  bool splitBefore;
  bool splitAfter;
  bool encrypted;
  bool saltSet;
  bool solid;
  bool subBlock;
  bool dir;
  int winSize;
  bool commentInHeader;
  bool version;

  RarFileHeader(int crc, int flags, int size)
      : super(crc, Rar.HEAD_FILE, flags, size) {
    splitBefore = (flags & Rar.LHD_SPLIT_BEFORE) != 0;
    splitAfter = (flags & Rar.LHD_SPLIT_AFTER) != 0;
    encrypted = (flags & Rar.LHD_PASSWORD) != 0;
    saltSet = (flags & Rar.LHD_SALT) != 0;
    solid = (flags & Rar.LHD_SOLID) != 0;
    subBlock = false;
    dir = (flags & Rar.LHD_WINDOWMASK) == Rar.LHD_DIRECTORY;
    winSize = dir ? 0 : 0x10000 << ((flags & Rar.LHD_WINDOWMASK) >> 5);
    commentInHeader = (flags & Rar.LHD_COMMENT) != 0;
    version = (flags & Rar.LHD_VERSION) != 0;
  }
}


class RarArchive {
  List<RarEntry> entries = [];
  RarVersion version = RarVersion.none;

  RarArchive(InputStreamBase input) {
    version = _readSignature(input);
    if (version == RarVersion.none || version == RarVersion.future) {
      throw ArchiveException("Invalid archive");
    }

    while (!input.isEOS) {
      var entryHeader = _readHeader(input);
      if (entryHeader is RarFileHeader) {
        _extractFile(input, entryHeader);
      }
    }
  }

  void _extractFile(InputStreamBase input, RarFileHeader header) {

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
    throw ArchiveException("Unsupported archive version");
  }

  RarHeader _readHeader15(InputStreamBase input) {
    var raw = input.readBytes(7);
    var crc = raw.readUint16();
    var type = raw.readByte();
    var flags = raw.readUint16();
    var size = raw.readUint16();

    switch (type) {
      case Rar.HEAD3_MAIN:
        type = Rar.HEAD_MAIN;
        break;
      case Rar.HEAD3_FILE:
        type = Rar.HEAD_FILE;
        break;
      case Rar.HEAD3_SERVICE:
        type = Rar.HEAD_SERVICE;
        break;
      case Rar.HEAD3_ENDARC:
        type = Rar.HEAD_ENDARC;
        break;
    }

    var entry = input.readBytes(size - 7);

    if (type == Rar.HEAD_MAIN) {
      var header = RarMainHeader(crc, flags, size);
      header.highPosAV = entry.readUint16();
      header.posAV = entry.readUint32();
      return header;
    }

    if (type == Rar.HEAD_FILE) {
      var header = RarFileHeader(crc, flags, size);

      var dataSize = entry.readUint32();
      var lowUnpackSize = entry.readUint32();
      var hostOS = entry.readByte();
      var fileCrc = entry.readUint32();
      var fileTime = entry.readUint32();
      var unpackVer = entry.readByte();
      var method = entry.readByte() - 0x30;
      var nameSize = entry.readUint16();
      var fileAttr = entry.readUint32();

      // RAR15 did not use the special dictionary size to mark dirs.
      if (unpackVer < 20 && (fileAttr & 0x10) != 0) {
        header.dir = true;
      }

      var cryptMethod = Rar.CRYPT_NONE;
      if (header.encrypted) {
        switch (unpackVer) {
          case 13:
            cryptMethod = Rar.CRYPT_RAR13;
            break;
          case 15:
            cryptMethod = Rar.CRYPT_RAR15;
            break;
          case 20:
          case 26:
            cryptMethod = Rar.CRYPT_RAR20;
            break;
          default:
            cryptMethod = Rar.CRYPT_RAR30;
            break;
        }
      }

      var systemType = Rar.HSYS_UNKNOWN;
      if (hostOS == Rar.HOST_UNIX || hostOS == Rar.HOST_BEOS) {
        systemType = Rar.HSYS_UNIX;
      } else if (hostOS < Rar.HOST_MAX) {
        systemType = Rar.HSYS_WINDOWS;
      }

      //var redirType = Rar.FSREDIR_NONE;

      // RAR 4.x Unix symlink.
      if (hostOS == Rar.HOST_UNIX && (fileAttr & 0xF000) == 0xA000) {
        //redirType = Rar.FSREDIR_UNIXSYMLINK;
        //redirName = "";
      }

      var inherited = false;//!fileBlock && (subFlags & SUBHEAD_FLAGS_INHERITED)!=0;

      var largeFile = (header.flags & Rar.LHD_LARGE) != 0;

      var highPackSize = 0;
      var highUnpackSize = 0;
      var unknownUnpackSize = false;
      if (largeFile) {
        highPackSize = entry.readUint32();
        highUnpackSize = entry.readUint32();
        unknownUnpackSize = lowUnpackSize == 0xffffffff && highUnpackSize == 0xffffffff;
      } else {
        highPackSize = highUnpackSize = 0;
        // UnpSize equal to 0xffffffff without LHD_LARGE flag indicates
        // that we do not know the unpacked file size and must unpack it
        // until we find the end of file marker in compressed data.
        unknownUnpackSize = lowUnpackSize == 0xffffffff;
      }

      int packSize = _INT32TO64(highPackSize, dataSize);
      int unpSize = _INT32TO64(highUnpackSize, lowUnpackSize);
      if (unknownUnpackSize) {
        unpSize = _INT64NDF;
      }

      var filename = entry.readString(size: nameSize);

      var fileData = input.readBytes(packSize);

      print("@@@@ $filename isDir: ${header.dir} ${fileData.length}");
      return header;
    }

    return RarHeader(crc, type, flags, size);
  }

  static const _INT64NDF = (0x7fffffff << 32) + 0x7fffffff;
  static int _INT32TO64(int high, int low) => (high << 32)+ low;

  RarHeader _readHeader50(InputStreamBase input) {
    throw ArchiveException("Unsupported archive version");
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
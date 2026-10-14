import 'dart:typed_data';

import '../codecs/tar/tar_file.dart';
import 'crc32.dart';

/// What [CodecsRecognizer.recognize] found from provided file headers
enum ArchiveFormat {
  gzip,
  zlib,
  bzip2,
  xz,
  zstd,
  zip,
  tar,
  unknown,
}

/// Detects an archive's format from its first bytes.
///
/// Every check looks only at the header, so a format can be recognized from
/// the part of a stream received so far, without the whole file. Below is how
/// many bytes each check needs: the first number is when it can give an answer,
/// the second is when it has read all the fields it checks:
///
/// | format | answers from | checks everything at |
/// | --- | --- | --- |
/// | zlib | 2 | 7 |
/// | gzip | 3 | 4 |
/// | zip | 4 | 4 |
/// | zstd | 4 | 5 |
/// | bzip2 | 4 | 10 |
/// | xz | 6 | 12 |
/// | tar | 263 for the ustar magic | 512 for the header checksum |
///
/// A check with fewer bytes than the second number skips the fields it has not
/// reached. So it can accept data that a whole header would not
///
/// A tar written before ustar has no magic and needs the whole 512 byte
/// header.
///
/// So six bytes give an answer for every format but tar. Twelve bytes run every
/// check but the tar checksum. [headerBytes] decides all of it.
/// A format with no header of its own, raw LZMA and raw deflate among them,
/// cannot be recognised this way and is not here
abstract final class CodecsRecognizer {
  /// The most bytes any of these checks reads, one tar header
  static const headerBytes = 512;

  /// `1f 8b`, then the compression method, which the format fixes at eight
  ///
  /// RFC 1952 reserves the top three bits of FLG. A decoder must refuse a
  /// member that sets them
  static bool isGZip(List<int> data) =>
      data.length >= 3 &&
      data[0] == 0x1f &&
      data[1] == 0x8b &&
      data[2] == 0x08 &&
      (data.length < 4 || (data[3] & 0xe0) == 0);

  /// zlib has no magic: the first byte identify the method and the window, and
  /// the two together are a multiple of 31. Be warned that this one
  /// might give some rare false positives on non-zlib files, there's no real
  /// way to verify zlib by header only.
  static bool isZLib(List<int> data) {
    if (data.length < 2) {
      return false;
    }
    final cmf = data[0];
    final flg = data[1];
    if ((cmf & 0x0f) != 8 ||
        (cmf >> 4) > 7 ||
        ((cmf << 8) | flg) % 31 != 0 ||
        (flg & 0x20) != 0) {
      return false;
    }
    if (data.length < 3) {
      return true;
    }
    final block = data[2];
    switch ((block >> 1) & 3) {
      case 0:
        // A stored block starts on the next byte with LEN, then NLEN
        return data.length < 7 ||
            (data[3] | data[4] << 8) == (~(data[5] | data[6] << 8) & 0xffff);
      case 1:
        return true;
      case 2:
        // HLIT is the top five bits of this byte. HDIST is the low five bits
        // of the next byte
        return (block >> 3) <= 29 &&
            (data.length < 4 || (data[3] & 0x1f) <= 29);
      default:
        return false;
    }
  }

  /// `BZh` and the block size, one of nine hundred kilobyte steps
  ///
  /// The magic is plain text. So we also match the six bytes after it when the
  /// data has them. A stream with blocks has the block magic there. An empty
  /// stream has the end of stream magic there
  static bool isBZip2(List<int> data) {
    if (data.length < 4 ||
        data[0] != 0x42 ||
        data[1] != 0x5a ||
        data[2] != 0x68 ||
        data[3] < 0x31 ||
        data[3] > 0x39) {
      return false;
    }
    var block = true;
    var end = true;
    for (var i = 4; i < data.length && i < 10; i++) {
      block = block && data[i] == _bzip2BlockMagic[i - 4];
      end = end && data[i] == _bzip2EndMagic[i - 4];
    }
    return block || end;
  }

  static const _bzip2BlockMagic = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59];
  static const _bzip2EndMagic = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90];

  /// `fd 37 7a 58 5a 00`
  ///
  /// Two bytes of stream flags follow the magic. Their CRC32 follows the flags.
  /// Every stream header has this CRC32. The check type of the blocks does not
  /// change that. The first flag byte must be zero. The top four bits of the
  /// second flag byte must be zero. We check each field once the data reaches
  /// it
  static bool isXZ(List<int> data) {
    if (data.length < 6 ||
        data[0] != 0xfd ||
        data[1] != 0x37 ||
        data[2] != 0x7a ||
        data[3] != 0x58 ||
        data[4] != 0x5a ||
        data[5] != 0x00) {
      return false;
    }
    if (data.length >= 7 && data[6] != 0) {
      return false;
    }
    if (data.length >= 8 && (data[7] & 0xf0) != 0) {
      return false;
    }
    if (data.length < 12) {
      return true;
    }
    final crc = data[8] | data[9] << 8 | data[10] << 16 | data[11] << 24;
    return getCrc32([data[6], data[7]]) == crc;
  }

  /// A zstd frame, or one of the skippable frames an archive may start with,
  /// whose magic is `184d2a50` to `184d2a5f` written low byte first
  static bool isZstd(List<int> data) {
    if (data.length < 4) {
      return false;
    }
    if (data[0] == 0x28 &&
        data[1] == 0xb5 &&
        data[2] == 0x2f &&
        data[3] == 0xfd) {
      // Bit 3 of the frame header descriptor is reserved and must be zero
      return data.length < 5 || (data[4] & 0x08) == 0;
    }
    return data[0] >= 0x50 &&
        data[0] <= 0x5f &&
        data[1] == 0x2a &&
        data[2] == 0x4d &&
        data[3] == 0x18;
  }

  /// `PK` and the record that follows: a local file, an empty archive's end of
  /// directory, or the first piece of a split one
  static bool isZip(List<int> data) {
    if (data.length < 4 || data[0] != 0x50 || data[1] != 0x4b) {
      return false;
    }
    final kind = (data[2] << 8) | data[3];
    if (kind == 0x3030) {
      return true;
    }
    return kind == 0x0304 || kind == 0x0506 || kind == 0x0606 || kind == 0x0708;
  }

  /// Recognizes tar by its 512-byte header. Pre-ustar tar has no magic, so only
  /// the checksum identifies it. The checksum field counts as spaces, and old
  /// writers summed bytes as signed.
  ///
  /// With a partial header, only the ustar magic can answer (all modern tars
  /// have it).
  ///
  /// A full header with a bad checksum isn't tar even with magic, as in `file`
  /// and libarchive, So do not add a magic fallback here: it would make us the
  /// only reader calling such a file a tar
  static bool isTar(List<int> data) {
    if (data.length < 512) {
      // 263 bytes reach past the ustar magic at 257
      return data.length >= 263 &&
          data[257] == 0x75 && // u
          data[258] == 0x73 && // s
          data[259] == 0x74 && // t
          data[260] == 0x61 && // a
          data[261] == 0x72; //  r
    }
    return tarHeaderChecksumMatches(
        data is Uint8List ? data : Uint8List.fromList(data.sublist(0, 512)));
  }

  /// Returns the format the data starts with, or [ArchiveFormat.unknown].
  ///
  /// zlib is checked last: its 2-byte header has no magic and can match the
  /// start of other formats. [withZLib] is off by default for the same reason,
  /// since the check gives false positives.
  static ArchiveFormat recognize(List<int> data, {bool withZLib = false}) {
    if (isTar(data)) {
      return ArchiveFormat.tar;
    }
    if (isXZ(data)) {
      return ArchiveFormat.xz;
    }
    if (isZstd(data)) {
      return ArchiveFormat.zstd;
    }
    if (isZip(data)) {
      return ArchiveFormat.zip;
    }

    // Last ones in order to ensure valid most-common archives are not
    // recognized for text files that start with magic from these codecs
    if (isGZip(data)) {
      return ArchiveFormat.gzip;
    }
    if (isBZip2(data)) {
      return ArchiveFormat.bzip2;
    }
    if (withZLib && isZLib(data)) {
      return ArchiveFormat.zlib;
    }
    return ArchiveFormat.unknown;
  }

  /// The extension the format is usually written with, without the dot
  ///
  /// [ArchiveExtension.tar] and [ArchiveExtension.tarShort] give the extension
  /// of a tar wrapped in the format, tar.bz2, tbz, etc.
  static ArchiveExtension? extensionOf(ArchiveFormat format) =>
      switch (format) {
        ArchiveFormat.gzip =>
          const ArchiveExtension('gz', tar: 'tar.gz', tarShort: 'tgz'),
        ArchiveFormat.zlib => const ArchiveExtension('zz'),
        ArchiveFormat.bzip2 =>
          const ArchiveExtension('bz2', tar: 'tar.bz2', tarShort: 'tbz'),
        ArchiveFormat.xz =>
          const ArchiveExtension('xz', tar: 'tar.xz', tarShort: 'txz'),
        ArchiveFormat.zstd =>
          const ArchiveExtension('zst', tar: 'tar.zst', tarShort: 'tzst'),
        ArchiveFormat.zip => const ArchiveExtension('zip'),
        ArchiveFormat.tar => const ArchiveExtension('tar'),
        ArchiveFormat.unknown => null,
      };
}

/// The extensions a format is written with, without the dot
final class ArchiveExtension {
  const ArchiveExtension(this.defaultName, {this.tar, this.tarShort});

  /// The format alone, `gz`
  final String defaultName;

  /// A tar inside the format, `tar.gz`. It is null for
  /// just tar, zip, zlib or other formats that are not compression-wrappers
  final String? tar;

  /// The one word name of a tar inside the format, `tgz`. It is null for
  /// just tar, zip, zlib or other formats that are not compression-wrappers
  final String? tarShort;

  @override
  String toString() => defaultName;
}

/// Reads the header of [data] the way [CodecsRecognizer.recognize] does
ArchiveFormat recognizeArchiveFormat(Uint8List data) =>
    CodecsRecognizer.recognize(data);

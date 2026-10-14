import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/src/util/output_memory_stream.dart';

import '../../util/archive_exception.dart';
import '../../util/file_content.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'tar_sparse.dart';

/*  File Header (512 bytes)
 *  Offset Size Field
 *      Pre-POSIX Header
 *  0     100  File name
 *  100   8    File mode
 *  108   8    Owner's numeric user ID
 *  116   8    Group's numeric user ID
 *  124   12   File size in bytes (octal basis)
 *  136   12   Last modification time in numeric Unix time format (octal)
 *  148   8    Checksum for header record
 *  156   1    Type flag
 *  157   100  Name of linked file
 *      UStar Format
 *  257   6    UStar indicator "ustar"
 *  263   2    UStar version "00"
 *  265   32   Owner user name
 *  297   32   Owner group name
 *  329   8    Device major number
 *  337   8    Device minor number
 *  345   155  Filename prefix
 */

/// A file entry decoded by [TarDecoder].
class TarFile {
  static const String normalFile = '0';
  static const String hardLink = '1';
  static const String symbolicLink = '2';
  static const String charSpec = '3';
  static const String blockSpec = '4';
  static const String directory = '5';
  static const String fifo = '6';
  static const String contFile = '7';
  // GNU headers whose content is the next entry's name, or the next entry's
  // link target, when it doesn't fit the 100 byte field.
  static const String longName = 'L';
  static const String longLinkName = 'K';
  // global extended header with meta data (POSIX.1-2001)
  static const String gExHeader = 'g';
  static const String gExHeader2 = 'G';
  // extended header with meta data for the next file in the archive
  // (POSIX.1-2001)
  static const String exHeader = 'x';
  static const String exHeader2 = 'X';
  static const String gnuSparse = 'S';

  /// The widest magnitude a base-256 numeric header field is written or read
  /// with: 2^53-1, the largest integer exact on every platform. A tar field
  /// can hold more, but it would not survive the trip through an int.
  static const int maxNumericField = 9007199254740991;

  /// The most a long name, pax header or sparse map may hold, as in Go
  /// archive/tar. Their content is read whole, so without a limit a small
  /// compressed archive could declare one large enough to exhaust memory.
  static const int maxMetadataSize = 1024 * 1024;

  // Pre-POSIX Format
  late String filename; // 100 bytes
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int fileSize = 0; // 12 bytes
  int lastModTime = 0; // 12 bytes
  int checksum = 0; // 8 bytes
  String typeFlag = '0'; // 1 byte
  String? nameOfLinkedFile; // 100 bytes
  // UStar Format
  String ustarIndicator = ''; // 6 bytes (ustar)
  String ustarVersion = ''; // 2 bytes (00)
  String ownerUserName = ''; // 32 bytes
  String ownerGroupName = ''; // 32 bytes
  int deviceMajorNumber = 0; // 8 bytes
  int deviceMinorNumber = 0; // 8 bytes
  String filenamePrefix = ''; // 155 bytes
  InputStream? _rawContent;
  FileContent? _content;
  TarSparse? sparse;
  var _ustarMagic = false;
  var _gnuMagic = false;
  int? _gnuRealSize;
  var _headerSize = 0;

  TarFile();

  /// Reads an entry from [input]. [size] is the size given by a preceding
  /// PAX header, which overrides the one in this entry's own header.
  TarFile.read(InputStream input,
      {bool storeData = true,
      Encoding? encoding,
      int? size,
      String? name,
      bool pax = false}) {
    final header = input.readBytes(512);

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a
    // null.
    filename = _parseString(header, 100, encoding, false);
    mode = _parseInt(header, 8);
    ownerId = _parseInt(header, 8);
    groupId = _parseInt(header, 8);
    fileSize = _parseInt(header, 12);
    lastModTime = _parseInt(header, 12);
    checksum = _parseInt(header, 8);
    typeFlag = _parseString(header, 1);
    nameOfLinkedFile = _parseString(header, 100, encoding, false);

    final at = header.position;
    header.setPosition(at + 5);
    final gnu = header.readByte() == 0x20 &&
        header.readByte() == 0x20 &&
        header.readByte() == 0;
    header.setPosition(at);
    _ustarMagic =
        String.fromCharCodes(header.peekBytes(5).toUint8List()) == 'ustar';
    _gnuMagic = _ustarMagic && gnu;
    ustarIndicator = _parseString(header, 6);
    if (ustarIndicator == 'ustar') {
      ustarVersion = _parseString(header, 2);
      ownerUserName = _parseString(header, 32);
      ownerGroupName = _parseString(header, 32);
      deviceMajorNumber = _parseInt(header, 8);
      deviceMinorNumber = _parseInt(header, 8);
      if (!gnu) {
        filenamePrefix = _parseString(header, 155, null, false);
        if (filenamePrefix.isNotEmpty) {
          filename = '$filenamePrefix/$filename';
        }
      }
    }

    final isMetadata = (filename == '././@LongLink' && size == null) ||
        typeFlag == longName ||
        typeFlag == longLinkName ||
        typeFlag == exHeader ||
        typeFlag == exHeader2 ||
        typeFlag == gExHeader ||
        typeFlag == gExHeader2;

    // A pax size record describes the entry it precedes, not the metadata
    // headers that may sit in between. Applying it to one of those would read
    // the wrong number of bytes and leave the stream mid-header.
    _headerSize = fileSize;
    if (size != null && !isMetadata) {
      fileSize = size;
    }
    // A size field can hold a negative number, which no entry can have.
    if (fileSize < 0) {
      throw ArchiveException('Invalid tar file size: $fileSize');
    }
    if (isMetadata && fileSize > maxMetadataSize) {
      throw ArchiveLimitException(
          'Tar metadata entry of $fileSize bytes is larger '
          'than the $maxMetadataSize allowed');
    }
    if ((typeFlag == hardLink &&
            fileSize > 0 &&
            (!_ustarMagic ||
                _gnuMagic ||
                (!pax && _passesUstarBid(header, at - 257)))) ||
        typeFlag == symbolicLink ||
        typeFlag == charSpec ||
        typeFlag == blockSpec ||
        typeFlag == directory ||
        typeFlag == fifo) {
      fileSize = 0;
    }
    if (typeFlag == '' && (name ?? filename).endsWith('/')) {
      fileSize = 0;
    }
    if (_gnuMagic && !isMetadata && typeFlag != 'A' && typeFlag != 'V') {
      _readGnuSparse(header, input);
    }

    // The decoder needs the content of the headers that carry the next
    // entry's metadata, even when it isn't storing file data.
    if (storeData ||
        filename == '././@LongLink' ||
        typeFlag == longName ||
        typeFlag == longLinkName ||
        typeFlag == exHeader ||
        typeFlag == exHeader2) {
      _rawContent = input.readBytes(fileSize);
    } else {
      input.skip(fileSize);
    }

    if (isFile && fileSize > 0) {
      final remainder = fileSize % 512;
      var skiplen = 0;
      if (remainder != 0) {
        skiplen = 512 - remainder;
        input.skip(skiplen);
      }
    }
  }

  static bool _passesUstarBid(InputStream header, int start) {
    final at = header.position;
    header.setPosition(start);
    final block = header.readBytes(512).toUint8List();
    header.setPosition(at);
    if (!tarHeaderChecksumMatches(block) ||
        String.fromCharCodes(block, 257, 265) != 'ustar\u000000') {
      return false;
    }
    for (final (offset, length) in const [
      (100, 8),
      (108, 8),
      (116, 8),
      (136, 12),
      (124, 12),
      (329, 8),
      (337, 8),
    ]) {
      if (!_validNumberField(block, offset, length)) {
        return false;
      }
    }
    return true;
  }

  static bool _validNumberField(Uint8List block, int offset, int length) {
    final marker = block[offset];
    if (marker == 0x80 || marker == 0xff || marker == 0) {
      return true;
    }
    final end = offset + length;
    var i = offset;
    while (i < end && block[i] == 0x20) {
      i++;
    }
    while (i < end && block[i] >= 0x30 && block[i] <= 0x37) {
      i++;
    }
    for (; i < end; i++) {
      if (block[i] != 0x20 && block[i] != 0) {
        return false;
      }
    }
    return true;
  }

  void _readGnuSparse(InputStream header, InputStream input) {
    header.setPosition(483);
    final realSize = header.readBytes(12).toUint8List();
    if (realSize[0] != 0) {
      _gnuRealSize = _tarAtol(realSize);
    }
    header.setPosition(386);
    if (header.peekBytes(1).readByte() == 0) {
      return;
    }
    final sparse = TarSparse();
    this.sparse = sparse;
    sparse.extended = _readSparseRegions(header, 4, sparse);
    while (sparse.extended && input.peekBytes(512).length >= 512) {
      readSparseExtension(input.readBytes(512));
    }
  }

  void readSparseExtension(InputStream block) {
    final sparse = this.sparse!;
    if (++sparse.extensionBlocks * 512 > maxMetadataSize) {
      throw ArchiveLimitException('Tar sparse map is larger than the '
          '$maxMetadataSize bytes allowed');
    }
    sparse.extended = _readSparseRegions(block, 21, sparse);
  }

  bool _readSparseRegions(InputStream block, int count, TarSparse sparse) {
    var end = false;
    for (var i = 0; i < count; i++) {
      final entry = block.readBytes(24).toUint8List();
      end = end || entry[0] == 0;
      if (!end) {
        sparse.add(_tarAtol(Uint8List.sublistView(entry, 0, 12)),
            _tarAtol(Uint8List.sublistView(entry, 12, 24)));
      }
    }
    return block.readByte() != 0;
  }

  int _tarAtol(Uint8List field) {
    if (field[0] & 0x80 == 0) {
      return _atol(field, 0, field.length, 8);
    }
    try {
      return _parseInt(InputMemoryStream(field), field.length);
    } on ArchiveException {
      return field[0] & 0x40 == 0 ? maxNumericField : -maxNumericField;
    }
  }

  static int _atol(List<int> bytes, int start, int end, int base) {
    var i = start;
    while (i < end && (bytes[i] == 0x20 || bytes[i] == 0x09)) {
      i++;
    }
    var sign = 1;
    if (i < end && bytes[i] == 0x2d) {
      sign = -1;
      i++;
    }
    var value = 0;
    for (; i < end; i++) {
      final digit = bytes[i] - 0x30;
      if (digit < 0 || digit >= base) {
        break;
      }
      if (value > (maxNumericField - digit) ~/ base) {
        return sign * maxNumericField;
      }
      value = value * base + digit;
    }
    return sign * value;
  }

  bool resolveSparse(InputStream data) {
    final sparse = this.sparse;
    if (sparse != null && sparse.mapInData) {
      var at = 0;
      for (var n = 512; at < fileSize; n *= 2) {
        final length = n < fileSize - at ? n : fileSize - at;
        if (at > data.length) {
          throw ArchiveException('Unexpected end of tar data');
        }
        final chunk = data.subset(position: at, length: length).toUint8List();
        at += length;
        if (sparse.readMap(chunk) != null) {
          break;
        }
      }
    }
    return applySparse();
  }

  bool applySparse() {
    final sparse = this.sparse;
    if (sparse == null) {
      return true;
    }
    if (!sparse.fits(fileSize)) {
      this.sparse = null;
      return false;
    }
    return true;
  }

  bool get isFile => typeFlag != TarFile.directory;

  bool get isSymLink => typeFlag == TarFile.symbolicLink;

  bool get isHardLink => typeFlag == TarFile.hardLink;

  InputStream? get rawContent => _rawContent;

  FileContent? get content {
    // What was set, or what was read, whichever there is
    if (_content == null && _rawContent != null) {
      _content = FileContentMemory(_rawContent!.toUint8List());
    }
    return _content;
  }

  set content(FileContent? data) => _content = data;

  Uint8List? get contentBytes => content?.readBytes();

  set contentBytes(Uint8List? data) =>
      data == null ? _content = null : _content = FileContentMemory(data);

  int get size => fileSize;

  @override
  String toString() => '[$filename, $mode, $fileSize]';

  /// With [headerOnly] the content and its padding are not written, so they
  /// can be streamed out a piece at a time rather than through one call
  void write(OutputStream output,
      {Encoding? filenameEncoder, bool headerOnly = false}) {
    fileSize = size;

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a null.
    final header = OutputMemoryStream();
    _writeString(header, filename, 100, filenameEncoder);
    _writeInt(header, mode, 8);
    _writeInt(header, ownerId, 8);
    _writeInt(header, groupId, 8);
    _writeInt(header, fileSize, 12);
    _writeInt(header, lastModTime, 12);
    _writeString(header, '        ', 8); // checksum placeholder
    _writeString(header, typeFlag, 1);
    if (nameOfLinkedFile != null) {
      _writeString(header, nameOfLinkedFile!, 100, filenameEncoder);
    } else {
      _writeString(header, '', 100);
    }
    _writeString(header, 'ustar', 6);
    _writeString(header, '00', 2);

    final remainder = 512 - header.length;
    header.writeBytes(Uint8List(remainder)); // typed arrays default to 0

    final headerBytes = header.getBytes();

    // The checksum is calculated by taking the sum of the unsigned byte values
    // of the header record with the eight checksum bytes taken to be ascii
    // spaces (decimal value 32). It is stored as a six digit octal number
    // with leading zeroes followed by a NUL and then a space.
    var sum = 0;
    for (var b in headerBytes) {
      sum += b;
    }

    var sumStr = sum.toRadixString(8); // octal basis
    while (sumStr.length < 6) {
      sumStr = '0$sumStr';
    }

    var checksumIndex = 148; // checksum is at 148th byte
    for (var i = 0; i < 6; ++i) {
      headerBytes[checksumIndex++] = sumStr.codeUnits[i];
    }
    headerBytes[154] = 0;
    headerBytes[155] = 32;

    output.writeBytes(header.getBytes());

    if (headerOnly) {
      return;
    }
    final body = contentStream;
    if (body != null) {
      output.writeStream(body);
    }

    final pad = padding;
    if (pad > 0) {
      output.writeBytes(Uint8List(pad));
    }
  }

  /// The payload stream following the header, read in chunks to avoid
  /// altering the read position of the original input
  InputStream? get contentStream {
    if (_content != null) {
      final stream = _content!.getStream();
      return stream.subset(position: stream.position);
    }
    return _rawContent?.subset();
  }

  /// The zeros that bring the content up to a 512 byte boundary
  int get padding {
    if (!isFile || fileSize <= 0) {
      return 0;
    }
    final remainder = fileSize % 512;
    return remainder == 0 ? 0 : 512 - remainder;
  }

  int _parseInt(InputStream input, int numBytes) {
    final bytes = input.readBytes(numBytes).toUint8List();

    // GNU tar stores values that don't fit the octal field, such as the size
    // of a file of 8GB or more, in base 256: the high bit of the first byte
    // marks the encoding, and the rest is a big endian two's complement
    // integer, with a set bit 0x40 meaning the value is negative.
    if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
      final inv = (bytes[0] & 0x40) != 0 ? 0xff : 0x00;
      var x = 0;
      for (var i = 0; i < bytes.length; ++i) {
        var c = bytes[i] ^ inv;
        if (i == 0) {
          c &= 0x7f;
        }
        // The field is wide enough for 88 bits, more than an int holds, and
        // a value that doesn't fit would come back as something unrelated
        // rather than as an error, so refuse anything wider than
        // maxNumericField. Checked before the multiply, so the bound is
        // divided by the base.
        // Built by arithmetic rather than shifts, because on the web an int
        // is a double and the bitwise operators there are 32 bit.
        if (x > maxNumericField ~/ 256) {
          throw ArchiveException('Tar header field is out of range');
        }
        x = x * 256 + c;
      }
      return inv == 0xff ? -x - 1 : x;
    }

    // Otherwise the field is a null or space terminated octal number.
    final end = bytes.indexOf(0);
    final s =
        String.fromCharCodes(bytes.sublist(0, end < 0 ? null : end)).trim();
    if (s.isEmpty) {
      return 0;
    }
    var x = 0;
    try {
      x = int.parse(s, radix: 8);
    } catch (e) {
      // Catch to fix a crash with bad group_id and owner_id values.
      // This occurs for POSIX archives, where some attributes like uid and
      // gid are stored in a separate PaxHeader file.
    }
    return x;
  }

  /// Parses a NUL-terminated or fixed-width field. Enabling [trim] drops
  /// space padding used in ustar magic and owner fields, but shouldn't
  /// be used for file names where spaces are significant. " .codecov.yml"`
  /// is not the same file as `".codecov.yml"`
  String _parseString(InputStream input, int numBytes,
      [Encoding? encoding, bool trim = true]) {
    final codes = input.readBytes(numBytes).toUint8List();
    final r = codes.indexOf(0);
    final s = codes.sublist(0, r < 0 ? null : r);
    final String text;
    try {
      text = encoding != null ? encoding.decode(s) : utf8.decode(s);
    } catch (e) {
      return trim ? String.fromCharCodes(s).trim() : String.fromCharCodes(s);
    }
    return trim ? text.trim() : text;
  }

  void _writeString(OutputStream output, String value, int numBytes,
      [Encoding? encoding]) {
    final codes = Uint8List(numBytes);
    final stringCodes = encoding?.encode(value) ?? utf8.encode(value);
    final end = min(stringCodes.length, numBytes);
    codes.setRange(0, end, stringCodes);
    output.writeBytes(codes);
  }

  void _writeInt(OutputStream output, int value, int numBytes) {
    var s = value.toRadixString(8);
    // Too wide for the octal field: base 256, which _parseInt reads back
    // Switched a digit later than GNU tar, because digits with no terminator
    // are read by older versions of this package and base 256 is not
    if (value < 0 || s.length > numBytes) {
      final bytes = Uint8List(numBytes);
      var m = value < 0 ? -value - 1 : value;
      // The same bound _parseInt reads back to, so wider is refused on both
      // sides
      if (m > maxNumericField) {
        throw ArchiveException('Tar header field is out of range: $value');
      }
      for (var i = numBytes - 1; i >= 0; --i) {
        bytes[i] = value < 0 ? 255 - (m % 256) : m % 256;
        m = m ~/ 256;
      }
      // Bits 0x80 and 0x40 of the first byte are the marker and the sign
      if (m != 0 || (value < 0 ? bytes[0] < 0xc0 : bytes[0] >= 0x40)) {
        throw ArchiveException('Tar header field is out of range: $value');
      }
      bytes[0] |= 0x80;
      output.writeBytes(bytes);
      return;
    }
    while (s.length < numBytes - 1) {
      s = '0$s';
    }
    _writeString(output, s, numBytes);
  }
}

/// Metadata from headers that carry no payload but describe the next entry,
/// such as GNU long names, links, and PAX records. Shared here for both
/// TarDecoder and the streamed reader
class TarMetadata {
  static const _space = 0x20;
  static const _equals = 0x3d;
  static const _newline = 0x0a;

  String? name;
  String? linkName;
  int? modTime;
  int? ownerId;
  int? groupId;

  /// A PAX size record that overrides the size of the upcoming entry
  int? size;

  bool pax = false;

  var _sparseSeen = false;
  String? _sparseName;
  int? _sparseSize;
  int? _sparseRealSize;
  TarSparse? _sparse;
  var _sparseMajor = 0;
  var _sparseMinor = 0;
  var _sparseOffset = -1;
  var _sparseLength = -1;

  int? get dataSize =>
      _sparseMajor == 1 && _sparseSize != null ? _sparseSize : size;

  TarFile? _legacy;
  String? _legacyName;
  Uint8List? _legacyNameStart;
  Encoding _legacyEncoding = utf8;
  TarFile? _orphan;

  TarFile? takeOrphan([bool atEnd = false]) {
    // Throwing when L, K or x header is last rejects valid GNU tar volumes:
    // gtar -M ends volume after such header and writes entry to next volume.
    // 12 of 114 volumes of 2 to 11 KiB end this way, so we accept archive end
    if (atEnd) {
      _dropLegacy();
    }
    final orphan = _orphan;
    _orphan = null;
    return orphan;
  }

  void _dropLegacy() {
    if (_legacy != null) {
      _orphan = _legacy;
    }
    _legacy = null;
    _legacyName = null;
    _legacyNameStart = null;
  }

  bool _nameFieldIs(String filename, Uint8List bytes) {
    bool same(List<int> codes) {
      if (codes.length != bytes.length) {
        return false;
      }
      for (var i = 0; i < codes.length; i++) {
        if (codes[i] != bytes[i]) {
          return false;
        }
      }
      return true;
    }

    try {
      if (same(_legacyEncoding.encode(filename))) {
        return true;
      }
    } catch (_) {}
    return same(filename.codeUnits);
  }

  /// True where [file] is one of those headers rather than an entry
  static bool describesNext(TarFile file) =>
      file.filename == '././@LongLink' ||
      file.typeFlag == TarFile.longName ||
      file.typeFlag == TarFile.longLinkName ||
      file.typeFlag == TarFile.gExHeader ||
      file.typeFlag == TarFile.gExHeader2 ||
      file.typeFlag == TarFile.exHeader ||
      file.typeFlag == TarFile.exHeader2;

  void sawHeader(TarFile file) {
    switch (file.typeFlag) {
      case 'A' || TarFile.gExHeader || TarFile.exHeader2 || TarFile.exHeader:
        pax = true;
      case TarFile.longLinkName || TarFile.longName || 'V':
        pax = false;
      default:
        if (!file._ustarMagic || file._gnuMagic) {
          pax = false;
        }
    }
  }

  /// Reads long name, link or PAX records from `rawContent` of [file]
  bool take(TarFile file, [Encoding? encoding]) {
    // GNU tar puts filenames in files when they exceed tar's native length.
    // Both kinds are named '././@LongLink', so only the type flag says
    // whether the content is the next entry's name or its link target.
    if (file.filename == '././@LongLink' ||
        file.typeFlag == TarFile.longName ||
        file.typeFlag == TarFile.longLinkName) {
      final codes = file.rawContent!.toUint8List();
      final end = codes.indexOf(0);
      final value = Uint8List.sublistView(codes, 0, end < 0 ? null : end);
      String text;
      // TarEncoder writes a long name with filenameEncoding, so decoding it
      // as UTF-8 breaks the round trip of any name over 100 bytes
      try {
        text = (encoding ?? utf8).decode(value);
      } catch (_) {
        text = String.fromCharCodes(value);
      }
      _dropLegacy();
      if (file.typeFlag == TarFile.longLinkName) {
        linkName = text;
      } else if (file.typeFlag == TarFile.longName) {
        name = text;
      } else if (value.length > 100 &&
          name == null &&
          linkName == null &&
          modTime == null &&
          ownerId == null &&
          groupId == null &&
          size == null) {
        _legacy = file;
        _legacyName = text;
        _legacyNameStart = Uint8List.fromList(value.sublist(0, 100));
        _legacyEncoding = encoding ?? utf8;
      } else {
        return false;
      }
      return true;
    }
    if (file.typeFlag == TarFile.gExHeader ||
        file.typeFlag == TarFile.gExHeader2) {
      _dropLegacy();
      // TODO handle PAX global header.
      return true;
    }
    if (file.typeFlag == TarFile.exHeader ||
        file.typeFlag == TarFile.exHeader2) {
      _dropLegacy();
      _readRecords(file.rawContent!.toUint8List());
      return true;
    }
    return false;
  }

  /// Applies the parsed metadata to the entry it describes and clears the
  /// state, ensuring it only affects a single entry
  void applyTo(TarFile file) {
    final paxSize = size;
    size = null;
    final legacyNameStart = _legacyNameStart;
    if (legacyNameStart != null &&
        _nameFieldIs(file.filename, legacyNameStart)) {
      file.filename = _legacyName!;
      _legacy = null;
    }
    _dropLegacy();
    if (name != null) {
      file.filename = name!;
      name = null;
    }
    if (linkName != null) {
      file.nameOfLinkedFile = linkName;
      linkName = null;
    }
    if (modTime != null) {
      file.lastModTime = modTime!;
      modTime = null;
    }
    if (ownerId != null) {
      file.ownerId = ownerId!;
      ownerId = null;
    }
    if (groupId != null) {
      file.groupId = groupId!;
      groupId = null;
    }
    _applySparse(file, paxSize);
  }

  void _applySparse(TarFile file, int? paxSize) {
    final name = _sparseName;
    if (name != null && name.isNotEmpty) {
      file.filename = name;
    }
    final readMap = _sparseSeen &&
        (file.typeFlag == TarFile.normalFile ||
            file.typeFlag == TarFile.gnuSparse) &&
        _sparseMajor == 1 &&
        _sparseMinor == 0;
    final realSize = file._gnuRealSize ??
        _sparseRealSize ??
        (_sparseMajor == 0 ? _sparseSize : null);
    var sparse = file.sparse;
    final records = _sparse;
    if (records != null) {
      if (sparse == null) {
        sparse = records;
      } else {
        sparse.regions.insertAll(0, records.regions);
        sparse.broken |= records.broken;
      }
    }
    if (readMap) {
      sparse ??= TarSparse();
      sparse.mapInData = true;
    }
    const noData = [
      TarFile.hardLink,
      TarFile.symbolicLink,
      TarFile.charSpec,
      TarFile.blockSpec,
      TarFile.directory,
      TarFile.fifo,
    ];
    if ((sparse == null && realSize == null) ||
        noData.contains(file.typeFlag)) {
      file.sparse = null;
    } else {
      file.sparse = (sparse ?? TarSparse())
        ..realSize = realSize ?? paxSize ?? file._headerSize;
    }
    _sparseSeen = false;
    _sparseName = null;
    _sparseSize = null;
    _sparseRealSize = null;
    _sparse = null;
  }

  void _addSparse() {
    (_sparse ??= TarSparse()).add(_sparseOffset, _sparseLength);
    _sparseOffset = -1;
    _sparseLength = -1;
  }

  static void _parseSparseMap(
      List<int> records, int start, int end, TarSparse sparse) {
    var offset = -1;
    var i = start;
    while (true) {
      var e = i;
      while (e < end && records[e] != 0x2c) {
        if (records[e] < 0x30 || records[e] > 0x39) {
          return;
        }
        e++;
      }
      final value = TarFile._atol(records, i, e, 10);
      if (offset < 0) {
        offset = value;
      } else {
        sparse.add(offset, value);
        offset = -1;
      }
      if (e == end) {
        return;
      }
      i = e + 1;
    }
  }

  static int? _paxNumber(List<int> records, int start, int end) {
    if (end - start > 64) {
      return -1;
    }
    final value = TarFile._atol(records, start, end, 10);
    return value < 0 || value == TarFile.maxNumericField ? null : value;
  }

  static int? _paxId(List<int> records, int start, int end) {
    if (start == end) {
      return null;
    }
    final number = _paxNumber(records, start, end);
    if (number == -1) {
      throw ArchiveException('Invalid tar pax id');
    }
    return number;
  }

  static int? _paxTime(List<int> records, int start, int end) {
    if (end - start > 128) {
      throw ArchiveException('Invalid tar pax mtime');
    }
    if (start == end) {
      return null;
    }
    var i = start;
    final negative = records[i] == 0x2d;
    if (negative) {
      i++;
    }
    var seconds = 0;
    for (; i < end && records[i] >= 0x30 && records[i] <= 0x39; i++) {
      final digit = records[i] - 0x30;
      if (seconds > (TarFile.maxNumericField - digit) ~/ 10) {
        return null;
      }
      seconds = seconds * 10 + digit;
    }
    if (i < end) {
      if (records[i] != 0x2e) {
        return null;
      }
      for (i++; i < end; i++) {
        if (records[i] < 0x30 || records[i] > 0x39) {
          return null;
        }
      }
    }
    return negative ? -seconds : seconds;
  }

  /// Records are "%d %s=%s\n", the length covering the whole record. Parsed by
  /// that length rather than split on newlines, and not decoded as UTF-8 up
  /// front: SCHILY.xattr and its kind hold raw bytes with embedded newlines
  void _readRecords(List<int> records) {
    var pos = 0;
    while (pos < records.length) {
      // The length field, terminated by a space.
      var sp = pos;
      while (sp < records.length && records[sp] != _space) {
        sp++;
      }
      if (sp == records.length) {
        break;
      }
      final length = int.tryParse(String.fromCharCodes(records, pos, sp));
      // A record has to at least hold the length field and its space,
      // and can't run past the end of the header.
      if (length == null ||
          length <= sp - pos + 1 ||
          length > records.length - pos) {
        break;
      }
      final recordEnd = pos + length;
      pos = recordEnd;

      // The keyword, terminated by '='. Keywords are portable
      // characters, so decoding them as ASCII is safe.
      var eq = sp + 1;
      while (eq < recordEnd && records[eq] != _equals) {
        eq++;
      }
      if (eq == recordEnd) {
        continue;
      }
      final keyword = String.fromCharCodes(records, sp + 1, eq);
      if (keyword != 'path' &&
          keyword != 'linkpath' &&
          keyword != 'size' &&
          keyword != 'mtime' &&
          keyword != 'uid' &&
          keyword != 'gid' &&
          keyword != 'GNU.sparse' &&
          !keyword.startsWith('GNU.sparse.')) {
        // TODO: support other pax headers.
        continue;
      }

      // The value runs to the end of the record, minus the newline.
      var valueEnd = recordEnd;
      if (records[valueEnd - 1] == _newline) {
        valueEnd--;
      }
      // The values of these keywords are UTF-8, but don't let a malformed
      // one abort the whole archive
      final bytes = records.sublist(eq + 1, valueEnd);
      String value;
      try {
        value = utf8.decode(bytes);
      } on FormatException {
        value = String.fromCharCodes(bytes);
      }
      switch (keyword) {
        case 'path':
          name = value;
          break;
        case 'linkpath':
          linkName = value;
          break;
        case 'size':
          // A pax size record overrides the header's own field. A file of 8GB
          // or more is stored that way in this format.
          final number = _paxNumber(records, eq + 1, valueEnd);
          if (number == null || number < 0) {
            throw ArchiveException('Invalid tar pax size');
          }
          size = number;
          break;
        case 'mtime':
          // Stored as seconds, with an optional fractional part that the
          // archive has nowhere to keep. Truncated off the string rather
          // than through a double, which for a long enough fraction would
          // round up and report the wrong second.
          modTime = _paxTime(records, eq + 1, valueEnd);
          break;
        case 'uid':
          ownerId = _paxId(records, eq + 1, valueEnd);
          break;
        case 'gid':
          groupId = _paxId(records, eq + 1, valueEnd);
          break;
        case 'GNU.sparse.name':
          _sparseName = value;
          break;
        case 'GNU.sparse.numblocks':
          _sparseOffset = -1;
          _sparseLength = -1;
          _sparseMajor = 0;
          _sparseMinor = 0;
          break;
        case 'GNU.sparse.map':
          _sparseMajor = 0;
          _sparseMinor = 1;
          if (valueEnd - eq - 1 <= 8 << 20) {
            _parseSparseMap(records, eq + 1, valueEnd, _sparse ??= TarSparse());
          }
          break;
        case 'GNU.sparse.offset' ||
              'GNU.sparse.numbytes' ||
              'GNU.sparse.size' ||
              'GNU.sparse.realsize' ||
              'GNU.sparse.major' ||
              'GNU.sparse.minor':
          final number = _paxNumber(records, eq + 1, valueEnd);
          if (number == -1) {
            (_sparse ??= TarSparse()).broken = true;
          } else if (number != null) {
            switch (keyword) {
              case 'GNU.sparse.offset':
                _sparseOffset = number;
                if (_sparseLength != -1) {
                  _addSparse();
                }
              case 'GNU.sparse.numbytes':
                _sparseLength = number;
                if (_sparseOffset != -1) {
                  _addSparse();
                }
              case 'GNU.sparse.size':
                _sparseSize = number;
              case 'GNU.sparse.realsize':
                _sparseRealSize = number;
              case 'GNU.sparse.major' when number <= 10:
                _sparseMajor = number;
              case 'GNU.sparse.minor' when number <= 10:
                _sparseMinor = number;
            }
          }
          break;
      }
      if (keyword == 'GNU.sparse' ||
          (keyword.length > 11 && keyword.startsWith('GNU.sparse.'))) {
        _sparseSeen = true;
      }
    }
  }
}

bool tarHeaderSizeIsNumber(Uint8List header) =>
    TarFile._validNumberField(header, 124, 12);

/// Validates the 512-byte [header] against its own checksum
/// (calculated with the checksum field replaced by spaces).
/// Because tar headers lack strict magic numbers, this is the
/// only proof that the block is actually a tar header
bool tarHeaderChecksumMatches(Uint8List header) {
  const space = 0x20;
  if (header.length < 512) {
    return false;
  }
  final words = ByteData.sublistView(header, 0, 512);
  var pairs = 0;
  var high = 0;
  for (var i = 0; i < 512; i += 4) {
    if (i == 148 || i == 152) {
      continue;
    }
    final w = words.getUint32(i, Endian.little);
    pairs += (w & 0x00ff00ff) + ((w >>> 8) & 0x00ff00ff);
    high += (w >>> 7) & 0x01010101;
  }
  final unsigned = 8 * space + (pairs & 0xffff) + (pairs >>> 16);
  // Implementations that predate unsigned char summed these signed
  final signed = unsigned -
      256 *
          ((high & 0xff) +
              ((high >>> 8) & 0xff) +
              ((high >>> 16) & 0xff) +
              (high >>> 24));
  // The stored value is octal, padded with spaces or nulls on either side of
  // the digits
  var p = 148;
  while (p < 156 && (header[p] == space || header[p] == 0)) {
    p++;
  }
  final start = p;
  var stored = 0;
  while (p < 156 && header[p] != space && header[p] != 0) {
    final digit = header[p] - 0x30;
    if (digit < 0 || digit > 7) {
      var digits = '';
      for (var q = start; q < 156 && header[q] != space && header[q] != 0;) {
        digits += String.fromCharCode(header[q++]);
      }
      final parsed = int.tryParse(digits, radix: 8);
      return parsed == unsigned || parsed == signed;
    }
    stored = stored * 8 + digit;
    p++;
  }
  return p > start && (stored == unsigned || stored == signed);
}

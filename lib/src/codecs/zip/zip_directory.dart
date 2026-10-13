import 'dart:convert';
import 'dart:math';
import '../../util/archive_exception.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import 'zip_file_header.dart';

/// The internal directory structure for a zip archive, used by [ZipDecoder].
class ZipDirectory {
  // End of Central Directory Record
  static const eocdSignature = 0x06054b50;
  static const zip64EocdLocatorSignature = 0x07064b50;
  static const zip64EocdLocatorSize = 20;
  static const zip64EocdSignature = 0x06064b50;
  static const zip64EocdSize = 56;
  // The smallest an EOCD record can be, which is the fixed fields with an
  // empty archive comment.
  static const eocdSize = 22;

  int filePosition = -1;
  int numberOfThisDisk = 0;
  int diskWithTheStartOfTheCentralDirectory = 0;
  int totalCentralDirectoryEntriesOnThisDisk = 0;
  int totalCentralDirectoryEntries = 0;
  int centralDirectorySize = 0;
  int centralDirectoryOffset = 0;
  String zipFileComment = '';
  final fileHeaders = <ZipFileHeader>[];

  void read(InputStream input,
      {String? password, bool verify = false, Encoding? filenameEncoding}) {
    // The caller may read on from where the stream was, or decode it again,
    // so leave the read position as it was found.
    final pos = input.position;
    try {
      _read(input, password, verify, filenameEncoding);
    } finally {
      input.setPosition(pos);
    }
  }

  void _read(InputStream input, String? password, bool verify,
      Encoding? filenameEncoding) {
    filePosition = _findSignature(input);
    if (filePosition < 0) {
      return;
    }

    input.setPosition(filePosition);
    final sig = input.readUint32();
    if (sig != eocdSignature) {
      return;
    }
    numberOfThisDisk = input.readUint16();
    diskWithTheStartOfTheCentralDirectory = input.readUint16();
    totalCentralDirectoryEntriesOnThisDisk = input.readUint16();
    totalCentralDirectoryEntries = input.readUint16();
    centralDirectorySize = input.readUint32();
    centralDirectoryOffset = input.readUint32();

    final len = input.readUint16();
    if (verify && len > input.length) {
      throw ArchiveException('zip: archive comment is truncated');
    }
    if (len > 0) {
      zipFileComment = input.readString(size: len, utf8: false);
    }

    _readZip64Data(input);

    var prefix = 0;
    final start = _prefixStart(input);
    if (start > centralDirectoryOffset &&
        !_signatureAt(input, centralDirectoryOffset, ZipFileHeader.signature)) {
      prefix = start - centralDirectoryOffset;
      centralDirectoryOffset = start;
    }

    if (centralDirectoryOffset < 0 ||
        centralDirectorySize < 0 ||
        centralDirectoryOffset > filePosition ||
        (verify &&
            centralDirectorySize > filePosition - centralDirectoryOffset)) {
      if (verify) {
        throw ArchiveException('zip: central directory is damaged');
      }
      return;
    }

    final dirContent = input.subset(
        position: centralDirectoryOffset,
        length: centralDirectorySize,
        bufferSize: min(centralDirectorySize, 1024));
    final fileBytes = verify
        ? input.subset(position: 0, length: centralDirectoryOffset)
        : input;

    while (!dirContent.isEOS) {
      final fileSig = dirContent.length >= 46 ? dirContent.readUint32() : 0;
      if (fileSig != ZipFileHeader.signature) {
        if (verify && !_hasPrefix(input)) {
          throw ArchiveException('zip: central directory is damaged');
        }
        break;
      }
      final header = ZipFileHeader()
        ..read(dirContent,
            fileBytes: fileBytes,
            password: password,
            verify: verify,
            prefix: prefix,
            filenameEncoding: filenameEncoding);
      fileHeaders.add(header);
    }
    if (verify &&
        fileHeaders.length % 0x10000 !=
            totalCentralDirectoryEntries % 0x10000) {
      throw ArchiveException(
          'zip: central directory entry count does not match');
    }
  }

  // do not accidentally recognize sfx as bad file
  bool _hasPrefix(InputStream input) => _prefixStart(input) >= 0;

  int _prefixStart(InputStream input) {
    var end = filePosition;
    final locator = end - zip64EocdLocatorSize;
    if (locator >= 0) {
      input.setPosition(locator);
      if (input.readUint32() == zip64EocdLocatorSignature) {
        end = locator - zip64EocdSize;
      }
    }
    final start = end - centralDirectorySize;
    if (start < 0 || start == centralDirectoryOffset) {
      return -1;
    }
    return _signatureAt(input, start, ZipFileHeader.signature) ? start : -1;
  }

  bool _signatureAt(InputStream input, int position, int signature) {
    if (position < 0) {
      return false;
    }
    input.setPosition(position);
    return input.length >= 4 && input.readUint32() == signature;
  }

  void _readZip64Data(InputStream input) {
    final ip = input.position;
    // Check for zip64 data.

    // Zip64 end of central directory locator
    // signature                       4 bytes  (0x07064b50)
    // number of the disk with the
    // start of the zip64 end of
    // central directory               4 bytes
    // relative offset of the zip64
    // end of central directory record 8 bytes
    // total number of disks           4 bytes

    final locPos = filePosition - zip64EocdLocatorSize;
    if (locPos < 0) {
      return;
    }
    final zip64 = input.subset(position: locPos, length: zip64EocdLocatorSize);

    var sig = zip64.readUint32();
    // If this isn't the signature we're looking for, nothing more to do.
    if (sig != zip64EocdLocatorSignature) {
      input.setPosition(ip);
      return;
    }

    /*final startZip64Disk =*/ zip64.readUint32();
    var zip64DirOffset = zip64.readUint64();
    /*final numZip64Disks =*/ zip64.readUint32();

    final before = locPos - zip64EocdSize;
    if (zip64DirOffset >= 0 &&
        zip64DirOffset < before &&
        !_signatureAt(input, zip64DirOffset, zip64EocdSignature) &&
        _signatureAt(input, before, zip64EocdSignature)) {
      zip64DirOffset = before;
    }
    if (!_signatureAt(input, zip64DirOffset, zip64EocdSignature)) {
      throw ArchiveException('Invalid zip64 end of central directory offset');
    }
    if (input.length < zip64EocdSize - 4) {
      input.setPosition(ip);
      return;
    }

    input.setPosition(zip64DirOffset);

    // Zip64 end of central directory record
    // signature                       4 bytes  (0x06064b50)
    // size of zip64 end of central
    // directory record                8 bytes
    // version made by                 2 bytes
    // version needed to extract       2 bytes
    // number of this disk             4 bytes
    // number of the disk with the
    // start of the central directory  4 bytes
    // total number of entries in the
    // central directory on this disk  8 bytes
    // total number of entries in the
    // central directory               8 bytes
    // size of the central directory   8 bytes
    // offset of start of central
    // directory with respect to
    // the starting disk number        8 bytes
    // zip64 extensible data sector    (variable size)
    sig = input.readUint32();
    if (sig != zip64EocdSignature) {
      input.setPosition(ip);
      return;
    }

    /*final zip64EOCDSize =*/ input.readUint64();
    input.readUint16(); // zip64Version
    input.readUint16(); // zip64VersionNeeded
    final zip64DiskNumber = input.readUint32();
    final zip64StartDisk = input.readUint32();
    final zip64NumEntriesOnDisk = input.readUint64();
    final zip64NumEntries = input.readUint64();
    final dirSize = input.readUint64();
    final dirOffset = input.readUint64();

    numberOfThisDisk = zip64DiskNumber;
    diskWithTheStartOfTheCentralDirectory = zip64StartDisk;
    totalCentralDirectoryEntriesOnThisDisk = zip64NumEntriesOnDisk;
    totalCentralDirectoryEntries = zip64NumEntries;
    centralDirectorySize = dirSize;
    centralDirectoryOffset = dirOffset;

    input.setPosition(ip);
  }

  int _findSignature(InputStream input) {
    const signatureSize = 4;
    // The directory and archive contents are written to the end of the zip
    // file. We need to search from the end to find these structures,
    // starting with the 'End of central directory' record (EOCD).
    // An EOCD record is at least [eocdSize] bytes, so its signature can never
    // start any later than that many bytes from the end of the file. Anything
    // after that point is too short to be a record and is not a candidate.
    // The positions searched are from the start of the stream, so this takes
    // its total length rather than the bytes after the read position, which
    // the caller may have moved.
    final lastCandidate = input.totalLength - eocdSize;
    if (lastCandidate < 0) {
      return -1;
    }
    // Because InputFileStream buffering is designed around forward
    // reading and not reverse reading like here, move the read position
    // back by chunks and then read those chunks of bytes, to avoid
    // thrashing the buffer updates.
    final pos = input.position;
    // Every candidate offset in [0, lastCandidate] has to be tested, and
    // testing the last one means reading the signatureSize bytes that follow
    // it, so this is how much of the file the search can need.
    final searchLength = lastCandidate + signatureSize;
    const bufferSize = 1024;
    final chunkSize = min(searchLength, bufferSize);

    var startPos = searchLength - chunkSize;

    while (true) {
      input.setPosition(startPos);
      // Need to search for the signature backwards from the end of the file,
      // without incurring file io seeking performance issues, so we read a
      // chunk of data starting from the end of the file and search backwards
      // within that. This avoids signatures from nested zips being found.
      final chunk = InputMemoryStream(input.readBytes(chunkSize).toUint8List());
      // A chunk of chunkSize bytes read at startPos can test the candidate
      // offsets startPos through startPos + chunkSize - signatureSize.
      for (var chunkPos = chunkSize - signatureSize;
          chunkPos >= 0;
          --chunkPos) {
        chunk.setPosition(chunkPos);
        final sig = chunk.readUint32();
        if (sig == eocdSignature) {
          input.setPosition(pos);
          return startPos + chunkPos;
        }
      }
      if (startPos == 0) {
        break;
      }
      // Step back so the next chunk's candidates end exactly one byte below
      // this chunk's lowest one, which keeps every candidate offset covered
      // including the signatures straddling the boundary between two chunks.
      // The step is positive whenever startPos is, because a chunk smaller
      // than bufferSize only happens when the whole search fits in one chunk,
      // and that leaves startPos at zero. So the loop always reaches zero.
      startPos = max(0, startPos - (chunkSize - (signatureSize - 1)));
    }

    input.setPosition(pos);
    return -1;
  }
}

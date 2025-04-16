import 'dart:math';
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

  int filePosition = -1;
  int numberOfThisDisk = 0;
  int diskWithTheStartOfTheCentralDirectory = 0;
  int totalCentralDirectoryEntriesOnThisDisk = 0;
  int totalCentralDirectoryEntries = 0;
  int centralDirectorySize = 0;
  int centralDirectoryOffset = 0;
  String zipFileComment = '';
  final fileHeaders = <ZipFileHeader>[];

  void read(InputStream input, {String? password}) {
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
    if (len > 0) {
      zipFileComment = input.readString(size: len, utf8: false);
    }

    _readZip64Data(input);

    final dirContent = input.subset(
        position: centralDirectoryOffset,
        length: centralDirectorySize,
        bufferSize: min(centralDirectorySize, 1024));

    while (!dirContent.isEOS) {
      final fileSig = dirContent.readUint32();
      if (fileSig != ZipFileHeader.signature) {
        break;
      }
      final header = ZipFileHeader()
        ..read(dirContent, fileBytes: input, password: password);
      fileHeaders.add(header);
    }
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
    final zip64DirOffset = zip64.readUint64();
    /*final numZip64Disks =*/ zip64.readUint32();

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

    /*final zip64EOCDSize =*/ input
      ..readUint64()
      /*final zip64Version =*/ ..readUint16() /*final zip64VersionNeeded =*/
      ..readUint16();
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
    if (input.length <= 4) {
      return -1;
    }
    // The directory and archive contents are written to the end of the zip
    // file. We need to search from the end to find these structures,
    // starting with the 'End of central directory' record (EOCD).
    // Because InputFileStream buffering is designed around forward
    // reading and not reverse reading like here, move the read position
    // back by chunks and then read those chunks of bytes, to avoid
    // thrashing the buffer updates.
    final pos = input.position;
    final length = input.length - 4;
    const bufferSize = 1024;
    final chunkSize = length < bufferSize ? length : bufferSize;

    var startPos = length - chunkSize;

    while (startPos >= 0) {
      input.setPosition(startPos);
      // Need to search for hte signature backwards from the end of the file,
      // without incurring file io seeking performance issues, so we read a
      // chunk of data starting from the end of the file and search backwards
      // within that. This avoids signatures from nested zips being found.
      final chunk = InputMemoryStream(input.readBytes(chunkSize).toUint8List());
      for (var chunkPos = chunkSize - 4; chunkPos >= 0; --chunkPos) {
        chunk.setPosition(chunkPos);
        final sig = chunk.readUint32();
        if (sig == eocdSignature) {
          input.setPosition(pos);
          return startPos + chunkPos;
        }
      }
      if (startPos > 0 && startPos < chunkSize) {
        startPos = 0;
      } else {
        startPos -= chunkSize;
      }
    }

    return -1;
  }
}

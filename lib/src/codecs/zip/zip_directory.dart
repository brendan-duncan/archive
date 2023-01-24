import '../../util/archive_exception.dart';
import '../../util/input_stream.dart';
import 'zip_file_header.dart';

class ZipDirectory {
  // End of Central Directory Record
  static const signature = 0x06054b50;
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

  Future<void> read(InputStream input, {String? password}) async {
    filePosition = await _findSignature(input);
    await input.setPosition(filePosition);
    final sig = await input.readUint32();
    if (sig != signature) {
      throw ArchiveException('Could not find End of Central Directory Record');
    }
    numberOfThisDisk = await input.readUint16();
    diskWithTheStartOfTheCentralDirectory = await input.readUint16();
    totalCentralDirectoryEntriesOnThisDisk = await input.readUint16();
    totalCentralDirectoryEntries = await input.readUint16();
    centralDirectorySize = await input.readUint32();
    centralDirectoryOffset = await input.readUint32();

    final len = await input.readUint16();
    if (len > 0) {
      zipFileComment = await input.readString(size: len, utf8: false);
    }

    await _readZip64Data(input);

    final dirContent = await input.subset(
        position: centralDirectoryOffset, length: centralDirectorySize);

    while (!dirContent.isEOS) {
      final fileSig = await dirContent.readUint32();
      if (fileSig != ZipFileHeader.signature) {
        break;
      }
      final header = ZipFileHeader();
      await header.read(dirContent, fileBytes: input, password: password);
      fileHeaders.add(header);
    }
  }

  Future<void> _readZip64Data(InputStream input) async {
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
    final zip64 =
        await input.subset(position: locPos, length: zip64EocdLocatorSize);

    var sig = await zip64.readUint32();
    // If this isn't the signature we're looking for, nothing more to do.
    if (sig != zip64EocdLocatorSignature) {
      await input.setPosition(ip);
      return;
    }

    /*final startZip64Disk =*/ await zip64.readUint32();
    final zip64DirOffset = await zip64.readUint64();
    /*final numZip64Disks =*/ await zip64.readUint32();

    await input.setPosition(zip64DirOffset);

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
    sig = await input.readUint32();
    if (sig != zip64EocdSignature) {
      await input.setPosition(ip);
      return;
    }

    /*final zip64EOCDSize =*/ await input.readUint64();
    /*final zip64Version =*/ await input.readUint16();
    /*final zip64VersionNeeded =*/ await input.readUint16();
    final zip64DiskNumber = await input.readUint32();
    final zip64StartDisk = await input.readUint32();
    final zip64NumEntriesOnDisk = await input.readUint64();
    final zip64NumEntries = await input.readUint64();
    final dirSize = await input.readUint64();
    final dirOffset = await input.readUint64();

    numberOfThisDisk = zip64DiskNumber;
    diskWithTheStartOfTheCentralDirectory = zip64StartDisk;
    totalCentralDirectoryEntriesOnThisDisk = zip64NumEntriesOnDisk;
    totalCentralDirectoryEntries = zip64NumEntries;
    centralDirectorySize = dirSize;
    centralDirectoryOffset = dirOffset;

    await input.setPosition(ip);
  }

  Future<int> _findSignature(InputStream input) async {
    final pos = input.position;
    final length = input.length;

    // The directory and archive contents are written to the end of the zip
    // file. We need to search from the end to find these structures,
    // starting with the 'End of central directory' record (EOCD).
    for (var ip = length - 5; ip >= 0; --ip) {
      await input.setPosition(ip);
      final sig = await input.readUint32();
      if (sig == signature) {
        await input.setPosition(pos);
        return ip;
      }
    }
    throw ArchiveException('Could not find End of Central Directory Record');
  }
}

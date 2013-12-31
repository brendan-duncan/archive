part of dart_archive;

/**
 *  File Header (512 bytes)
 *  Offst Size Field
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

class TarFile {
  // Pre-POSIX Format
  String filename;
  int mode;
  int ownerId;
  int groupId;
  int fileSize;
  int lastModTime;
  int checksum;
  String typeFlag;
  String nameOfLinkedFile;
  // UStar Format
  String ustarIndicator = '';
  String ustarVersion = '';
  String ownerUserName = '';
  String ownerGroupName = '';
  int deviceMajorNumber = 0;
  int deviceMinorNumber = 0;
  String filenamePrefix = '';
  bool isFile;
  List<int> data;

  TarFile(InputBuffer input) {
    InputBuffer header = new InputBuffer(input.readBytes(512));

    filename = _parseString(header, 100);
    mode = _parseInt(header, 8);
    ownerId = _parseInt(header, 8);
    groupId = _parseInt(header, 8);
    fileSize = _parseInt(header, 12, 8);
    lastModTime = _parseInt(header, 12);
    checksum = _parseInt(header, 8);
    typeFlag = _parseString(header, 1);
    nameOfLinkedFile = _parseString(header, 100);

    ustarIndicator = _parseString(header, 6);
    if (ustarIndicator == 'ustar') {
      ustarVersion = _parseString(header, 2);
      ownerUserName = _parseString(header, 32);
      ownerGroupName = _parseString(header, 32);
      deviceMajorNumber = _parseInt(header, 8);
      deviceMinorNumber = _parseInt(header, 8);
    }

    isFile = typeFlag != '5'; // DIRECTORY

    data = input.readBytes(fileSize);

    if (isFile && fileSize > 0) {
      int remainder = fileSize % 512;
      int skiplen = 0;
      if (remainder != 0) {
        skiplen = 512 - remainder;
        input.skip(skiplen);
      }
    }
  }

  int _parseInt(InputBuffer input, int numBytes, [int radix]) {
    String s = _parseString(input, numBytes);
    return int.parse('0' + s, radix: radix);
  }

  String _parseString(InputBuffer input, int numBytes) {
    List<int> codes = input.readBytes(numBytes);
    int r = codes.indexOf(0);
    List<int> s = codes.sublist(0, r < 0 ? null : r);
    return new String.fromCharCodes(s).trim();
  }
}

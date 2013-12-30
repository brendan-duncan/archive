part of dart_archive;

/**
 * File Header
 * 100 File name
 * 8 File mode
 * 8 Owner's numeric user ID
 * 8 Group's numeric user ID
 * 12  File size in bytes (octal basis)
 * 12  Last modification time in numeric Unix time format (octal)
 * 8 Checksum for header record
 * 1 Link indicator (file type)
 * 100 filename prefix
 * 6 UStar indicator "ustar"
 * 2 UStar version "00"
 * 32 Owner user name
 * 32 Owner group name
 * 8 Device major number
 * 8 Device minor number
 * 155 Filename prefix
 */
class TarFile {
  String filename;
  int mode;
  int ownerId;
  int groupId;
  int fileSize;
  int lastModificationTime;
  int checksum;
  int typeFlag;
  String filenamePrefix;
  String ustarIndicator;
}

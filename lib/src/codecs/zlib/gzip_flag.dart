class GZipFlag {
  static const int signature = 0x8b1f;
  static const int deflate = 8;
  static const int text = 0x01;
  static const int hcrc = 0x02;
  static const int extra = 0x04;
  static const int name = 0x08;
  static const int comment = 0x10;

  // enum OperatingSystem
  static const int osFat = 0;
  static const int osAmiga = 1;
  static const int osVMS = 2;
  static const int osUnix = 3;
  static const int osVmCms = 4;
  static const int osAtariTos = 5;
  static const int osHpfs = 6;
  static const int osMacintosh = 7;
  static const int osZSystem = 8;
  static const int osCpM = 9;
  static const int osTops20 = 10;
  static const int osNtfs = 11;
  static const int osQDos = 12;
  static const int osAcornRiscOS = 13;
  static const int osUnknown = 255;
}

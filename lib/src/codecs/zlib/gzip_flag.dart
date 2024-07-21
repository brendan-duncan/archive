class GZipFlag {
  static const signature = 0x8b1f;
  static const deflate = 8;
  static const text = 0x01;
  static const hcrc = 0x02;
  static const extra = 0x04;
  static const name = 0x08;
  static const comment = 0x10;

  // enum OperatingSystem
  static const osFat = 0;
  static const osAmiga = 1;
  static const osVMS = 2;
  static const osUnix = 3;
  static const osVmCms = 4;
  static const osAtariTos = 5;
  static const osHpfs = 6;
  static const osMacintosh = 7;
  static const osZSystem = 8;
  static const osCpM = 9;
  static const osTops20 = 10;
  static const osNtfs = 11;
  static const osQDos = 12;
  static const osAcornRiscOS = 13;
  static const osUnknown = 255;
}

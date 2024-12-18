import 'dart:io';

import 'package:posix/posix.dart' as posix;

bool isPosixSupported() {
  try {
    return (Platform.isMacOS || Platform.isLinux || Platform.isAndroid) &&
        posix.isPosixSupported;
  } catch (_) {
    return false;
  }
}

void chmod(String path, String permissions) {
  posix.chmod(path, permissions);
}

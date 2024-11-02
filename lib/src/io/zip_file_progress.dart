import 'dart:io';

enum ZipFileOperation { include, skip, cancel }

typedef ZipFileProgress = ZipFileOperation Function(
    FileSystemEntity entity, double progress);

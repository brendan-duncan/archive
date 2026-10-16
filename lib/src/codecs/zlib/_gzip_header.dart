import 'dart:math';

import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
import '../../util/input_stream.dart';
import 'gzip_flag.dart';

void checkGZipHeaderCrc(InputStream input) {
  final start = input.position;
  try {
    if (_headerCrcFails(input, start)) {
      throw ArchiveChecksumException('Invalid gzip header checksum');
    }
  } finally {
    input.setPosition(start);
  }
}

bool _headerCrcFails(InputStream input, int start) {
  if (input.length < 10) {
    return false;
  }
  if (input.readByte() != 0x1f ||
      input.readByte() != 0x8b ||
      input.readByte() != GZipFlag.deflate) {
    return false;
  }
  final flags = input.readByte();
  if (flags & GZipFlag.hcrc == 0) {
    return false;
  }
  input.skip(6);
  if (flags & GZipFlag.extra != 0) {
    if (input.length < 2) {
      return false;
    }
    final size = input.readByte() | input.readByte() << 8;
    if (input.length < size) {
      return false;
    }
    input.skip(size);
  }
  for (final flag in const [GZipFlag.name, GZipFlag.comment]) {
    if (flags & flag != 0) {
      while (!input.isEOS && input.readByte() != 0) {}
    }
  }
  if (input.length < 2) {
    return false;
  }
  final end = input.position;
  final expected = input.readByte() | input.readByte() << 8;
  input.setPosition(start);
  var crc = 0;
  for (var left = end - start; left > 0;) {
    final count = min(left, 8192);
    crc = getCrc32(input.readBytes(count).toUint8List(), crc);
    left -= count;
  }
  return crc & 0xffff != expected;
}

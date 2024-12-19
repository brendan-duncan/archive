import '_crc64_html.dart' if (dart.library.io) '_crc64_io.dart';

int getCrc64(List<int> array, [int crc = 0]) => getCrc64_(array, crc);

bool isCrc64Supported() => isCrc64Supported_();

export '_gzip_decoder_stub.dart'
    if (dart.library.io) '_gzip_decoder_io.dart'
    if (dart.library.js) '_gzip_decoder_web.dart';

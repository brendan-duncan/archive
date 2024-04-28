import '_zlib_decoder_base.dart';

ZLibDecoderBase get platformGZipDecoder => throw UnsupportedError(
    'Cannot create a gzip decoder without dart:html or dart:io.');

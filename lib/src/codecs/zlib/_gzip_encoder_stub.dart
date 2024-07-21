import '_zlib_encoder_base.dart';

ZLibEncoderBase get platformGZipEncoder => throw UnsupportedError(
    'Cannot create a gzip encoder without dart:html or dart:io.');

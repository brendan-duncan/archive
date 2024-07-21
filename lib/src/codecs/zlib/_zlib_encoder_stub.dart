import '_zlib_encoder_base.dart';

ZLibEncoderBase get platformZLibEncoder => throw UnsupportedError(
    'Cannot create a zlib encoder without dart:html or dart:io.');

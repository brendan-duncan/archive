import 'dart:typed_data';

import 'aes_ctr.dart';

@Deprecated('Use AesCtr')
class AesDecrypt {
  static const aes128 = 0;
  static const aes192 = 1;
  static const aes256 = 2;

  int mode;
  Uint8List key;
  Uint8List? iv;

  final Uint8List _key;

  AesDecrypt(this.key, {this.mode = aes256})
      : _key = Uint8List.fromList(
            Uint8List.sublistView(key, 0, const [16, 24, 32][mode]));

  void decryptCrt(Uint8List buffer) =>
      AesCtr(_key, Uint8List(16)).process(buffer);
}

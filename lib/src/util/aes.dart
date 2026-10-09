import 'dart:typed_data';
import 'encryption.dart';

class Uint8ListEquality {
  static bool equals(Uint8List mac, Uint8List computedMac) {
    if (mac.length != computedMac.length) {
      return false;
    }
    var v = 0;
    for (var i = 0; i < mac.length; i++) {
      v |= mac[i] ^ computedMac[i];
    }
    return v == 0;
  }
}

class AesCipherUtil {
  static PcHMac getMacBasedPRF(Uint8List derivedKey) {
    var mac = PcHMac(PcSHA1Digest(), 64);
    mac.init(PcKeyParameter(derivedKey));
    return mac;
  }

  static void prepareBuffAESIVBytes(Uint8List buff, int nonce) {
    buff[0] = nonce & 0xFF;
    buff[1] = (nonce >> 8) & 0xFF;
    buff[2] = (nonce >> 16) & 0xFF;
    buff[3] = (nonce >> 24) & 0xFF;

    for (int i = 4; i <= 15; ++i) {
      buff[i] = 0;
    }
  }
}

// AesDecrypt
class Aes {
  int nonce = 1;
  Uint8List iv = Uint8List(16);
  Uint8List counterBlock = Uint8List(16);
  Uint8List derivedKey;
  int aesKeyStrength;
  bool encrypt;
  PcAESEngine? aesEngine;
  late PcHMac _macGen;
  late Uint8List mac;

  /// Encrypts or decrypts all of the data in one call, leaving the
  /// authentication code in [mac].
  int processData(Uint8List buff, int start, int len) {
    update(buff, start, len);
    finish();
    return len;
  }

  /// Encrypts or decrypts the next [len] bytes of the data in place.
  ///
  /// The counter advances a block at a time, so every call but the last has
  /// to pass a multiple of 16 bytes. Call [finish] after the last one.
  void update(Uint8List buff, int start, int len) {
    if (!encrypt) {
      _macGen.update(buff, start, len);
    }

    for (int j = start; j < start + len; j += 16) {
      int loopCount = j + 16 <= start + len ? 16 : start + len - j;
      AesCipherUtil.prepareBuffAESIVBytes(iv, nonce);
      aesEngine?.processBlock(iv, 0, counterBlock, 0);
      for (int k = 0; k < loopCount; ++k) {
        buff[j + k] ^= counterBlock[k];
      }
      ++nonce;
    }

    if (encrypt) {
      _macGen.update(buff, start, len);
    }
  }

  /// Computes the authentication code of everything passed to [update],
  /// storing it in [mac] and returning it.
  Uint8List finish() {
    mac = Uint8List(_macGen.macSize);
    _macGen.doFinal(mac, 0);
    mac = mac.sublist(0, 10);
    _macGen.reset();
    return mac;
  }

  Aes(this.derivedKey, Uint8List hmacDerivedKey, this.aesKeyStrength,
      {this.encrypt = false}) {
    aesEngine = PcAESEngine();
    aesEngine!.init(true, PcKeyParameter(derivedKey));
    _macGen = AesCipherUtil.getMacBasedPRF(hmacDerivedKey);
  }
}

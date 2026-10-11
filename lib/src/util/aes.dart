import 'dart:typed_data';
import 'aes_ctr.dart';
import 'sha1.dart';

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
  static HmacSha1 getMacBasedPRF(Uint8List derivedKey) => HmacSha1(derivedKey);
}

class Aes {
  Uint8List derivedKey;
  int aesKeyStrength;
  bool encrypt;
  late AesCtr _ctr;
  late HmacSha1 _macGen;
  late Uint8List mac;

  int processData(Uint8List buff, int start, int len) {
    if (!encrypt) {
      _macGen.update(buff, start, len);
    }

    _ctr.process(buff, start, start + len);

    if (encrypt) {
      _macGen.update(buff, start, len);
    }

    mac = Uint8List(HmacSha1.macSize);
    _macGen.finish(mac, 0);
    mac = mac.sublist(0, 10);

    return len;
  }

  /// Processes `buff[start, start + len)` as one piece of a longer entry,
  /// which [processData] cannot do since it finishes [mac] on every call.
  /// [finishMac] sets [mac] once every piece is done
  void processPart(Uint8List buff, int start, int len) {
    if (!encrypt) {
      _macGen.update(buff, start, len);
    }
    _ctr.process(buff, start, start + len);
    if (encrypt) {
      _macGen.update(buff, start, len);
    }
  }

  void finishMac() {
    final full = Uint8List(HmacSha1.macSize);
    _macGen.finish(full, 0);
    mac = full.sublist(0, 10);
  }

  Aes(this.derivedKey, Uint8List hmacDerivedKey, this.aesKeyStrength,
      {this.encrypt = false}) {
    _ctr =
        AesCtr(derivedKey, Uint8List(16)..[0] = 1, littleEndianCounter: true);
    _macGen = AesCipherUtil.getMacBasedPRF(hmacDerivedKey);
  }
}

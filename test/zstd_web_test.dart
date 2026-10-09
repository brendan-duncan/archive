import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/zstd/zstd_bit_reader.dart';
import 'package:test/test.dart';

import '_zstd_util.dart';

// This file deliberately avoids dart:io so that it can be run on the web
// targets as well as the VM, with `dart test -p chrome` or `-p node`. Both
// the bit reader and the checksum are chosen per platform, and zstd_test.dart
// only ever runs the native ones.

// synth(20000, 11) compressed by the reference library at level 3, with a
// checksum. See test/_data/zstd/gen_fixtures.js.
const _synthZst =
    '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'
    '3NJ6T6b1V1s6t2O99ym5vVqZxavV3hhlrfFybocyrhbPNZ5q5fm4FF4Q0RiWHGBikCk7'
    'FlhyQolTEiOk5vzRoAA/eImNoMOXMbArnFIRmdTHCFRP1IMeNAFb/AjKj9s2dl3DCgl4'
    'rFk064DGCV2CXGggzyMWTsTwJ4eUGYsCdfFQooSQKVnm6IADiQ82hvyT2wwbyfYln1Dr'
    'mhVO5jqzfua+/NKr5f03j2f17i23x/os3G9vV/tOyi6fnuwyH2W3vfRanffO23r0/PMr'
    'v81t6kUwzhCccT0ZpTzT73vNyko+gooHj6NSbdqw4XTJ1d3IVd7ieLWm8r8B8FTg3Tkh'
    'gtpmUqY7ZkrlcePnDhoxTBRBRJYmZCoSbdK0RYAT1oQ60pUqg8MSqR7AaugyBwoNiHak'
    'AimoocmFOKTCM1TiBSIp2W2/y93O3PFbc19kudspFxdXn7mw2eO2vqXL195F7drr+bX5'
    'iJ2wRhgmOuCK6oVPl05MyEjJOUKGpi05EPAplKmLExpFNMCIB+EGPG7sgKQTgKFQE4tj'
    'Or3YW8e51Yj1LBrDGC6d/2RXGp8CbQW13fr3xFqe3NTe116Z7ie/hRuGnfaJE6vDBNMT'
    'KA6k8MWIHl5bj9RoWcVBBGSSoNI0hsIGqE51oVDi0gcZfAE0KlOnMUZX2rDhBMhRqTJB'
    'fgQqQqcFMovQhCp1J4csBlihh6kxKIZQ8ajUKDOnOjN+YryhwM8sjY0ivrQ4UmKszotP'
    'djTpESOEZ8sKDSlmGAkCDCQlskAvTF5CuBgCIn2Q4SDUQJtDPTDxmRFlVbjBhzQt0BBq'
    'caeRljUKKKMBCwlWUIvcvtJaz9w7Wawed1XK+sur6vqhANvO1/0RJIYcDRoJ0UAdUJrE'
    'IHnwQV9mAKLrz4wevAhByBARIIKw8rKlhRWlaFDV9UMB2pyXsbytuXFueeF5Urm9t8/m'
    'zu/eWbe//rL5HEbe6S3d7yn43X4nK50hR+m3yqacpAmKCJpjvDpBqlPEzHRYgsanQJmO'
    'eIGNEUNIRLIh6Y2LFlxQUJgSavvzAZeCAhyEGKt0BKgdQgoGeS3k4OTPEK8eutI02WSV'
    'ApM/R7iUXHIT1eCg3TFWBuO1Sw8SFxeKS0nGQpXJMkNHVwPQfJEZe2GMT44gxiIQa8GD'
    'MUaevr6IeuAIUzdOyACCOmNGqMCBKAogRSUDMEUwVK2KS3xBkhWjCCh66LCQ4VClQDMI'
    'yJIgYqpQkRc1LGBAB3KaF41m8IjjJQJgS7fY8+tt5f77nL2UHrwsMu2oUU/aO/LOqHVd'
    'j0ZwtbnvtJyExf+05UfPXaRy/GipqlQICYskUmgzTL3BAcQGVS1oMIJlAitOnQEDZYLZ'
    '3yT9d6UHKdHsx+2bVT7SodL717vsJqW0ypqBYqhxJTKEEBEREZGRGWmTNrEEFlOEIOWY'
    '2QESQLAoiqNIDKMQioIoiCHGKEIIQQYhIiCEEFJERqQPA6UUcGg8MV44QmDaSnl+T8Hw'
    'WU0bHtMPscKrbfMEP2nDcnY8lB/YEt11cJx1NxII3L8gBZYqkVALxcLbqxISdiAvsMfU'
    'C8IIOk7B71pIT5jQQSBcGelv0yEDOcQLYkfLqHFd3bROfFK7Y/sfWMe4zM4CfWXOCDHU'
    'Wx2zIznx5+jGHAa5gZmp1ZjYzo2dTDjWDx/r+FtAR2oLM8LvUCrqmNjIl/NRwPLLD2Ny'
    'uf2Hj6XpmVT6ifB909QOOfzMSSiZxCZkJK3+jr7NfOnDjcW5uL2xBYsrD/riTUT8BNKB'
    'JT/fkWliwER+gB+/mbcz6iCCbzTA2h6UhfBzIq0qxTYGbVBaX0IJOtJdWRMNxYl+OW0v'
    'jKK8COWKE4Wow9px9Zhu0MxxZH7uqJxRIsHiRPdWqqzbsioQUoabZ/MqkR8FzhayUY1B'
    'v32LyG4DfSW1nNZLZVX24rNP1s6yMbQCDgftqvPqAIUDdbCTRy0LdvoDRPyXkC2gR9Hp'
    'sWVoVL0qrWGsKgbekrdNfPxK4PATqB6ANptoKVcVXp5W5NL0o1XeDjIWgxKZ+DSkFt/b'
    'jOYR8mMAN07Rw/Qg1JpW04SiUAQG44VYEkzcjaSzFK+Y1CbDWuK37sk3Tzfu+KtLSiRA'
    'ZvtK1wZQukeP38CNuHL7PopoRMr8uDQYL1zCe/8wTWU+nL+BU6EnPNLbSaU+YPu62Ig2'
    'vzlcKHYIKVjWmQE3mHHuCkihzZToni3bCcIGlBDwSofCk/iUgwkCukjrY6VLlkURy4dO'
    'RaHL1fEXMIxZMh+uNiEurmJQpm6lZBNZI/ZSQtiBiF90QyVbQ3GRFG402xfX5wKY8beH'
    'EIm/HWsFvocH95lQGXgI8SQfGM8cDPcTbFqkRNfbCpZx/UkAQST+wOMylg5DIbZwQOZe'
    'iHsPhEGokWIhnTvCev8AD6EEzZkC7Aec8+HMa7TheXkNHBqvrkTFcHlwoZ3AJnRal1zf'
    'X8zy4trdAIXSBxENwnIcxQs7H8Kn6OZ7EnXocfH0f29tHd4BYJqFd1ZEoO52KStqgVy5'
    'YsjnYq8vV9XuTnQDgdxlxZyxGfDlhb+piQXMjyzc5Akkg7KstWFLYsmt0HjZBGyLE3jW'
    '1Eimx7ZLdDUQM7j3sPXmCVPGybvHdoZDdMCSwBdtZobqzQiWkkQqiBA7iVyTAqC4PB1S'
    'lTvpowFJ+scUx4s=';

void main() {
  group('zstd on every platform', () {
    test('picks the implementation this platform can run', () {
      // An int is a JavaScript number exactly where 1 and 1.0 are identical,
      // and there the 64 bit reader and checksum would give wrong answers.
      // Everywhere else they are correct and faster.
      expect(ZstdBitReader.has64BitInts, !identical(1, 1.0));
    });

    test('decodes', () {
      final data = base64.decode(_synthZst);
      final decoded =
          ZstdDecoder().decodeBytes(data, verify: true, throwOnError: true);
      expect(decoded, synth(20000, 11));
    });

    test('verify catches a damaged checksum', () {
      final data = Uint8List.fromList(base64.decode(_synthZst));
      data[data.length - 1] ^= 1;
      expect(ZstdDecoder().decodeBytes(data).length, 20000);
      expect(
          ZstdDecoder().decodeStream(
              InputMemoryStream(data), OutputMemoryStream(),
              verify: true),
          isFalse);
    });

    test('encodes', () {
      // Hashing and reading words are done differently where ints are 32
      // bits wide, so the encoder's output differs between platforms, but it
      // must decode to the same thing everywhere.
      final data = synth(100000, 12);
      for (final level in [-3, 1, 3, 5, 9, 16]) {
        final z = ZstdEncoder().encodeBytes(data, level: level, checksum: true);
        expect(ZstdDecoder().decodeBytes(z, verify: true, throwOnError: true),
            data,
            reason: 'level $level');
      }
    });

    test('truncations are refused', () {
      final data = base64.decode(_synthZst);
      for (var n = 0; n < data.length; n += 7) {
        expect(
            ZstdDecoder().decodeStream(
                InputMemoryStream(Uint8List.sublistView(data, 0, n)),
                OutputMemoryStream()),
            isFalse,
            reason: 'truncated to $n bytes');
      }
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_constants.dart';
import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:archive/src/util/xxh64.dart';
import 'package:test/test.dart';

import '_zstd_util.dart';

// This file deliberately avoids dart:io so that it can be run on the web
// targets as well as the VM, with `dart test -p chrome` or `-p node`. The bit
// container, the sequence row layout, the literal loops and XXH64 are all
// written twice and picked per platform, so a test that only ever ran on the
// VM would guard none of it.
//
// Vectors written by zstd 1.5.7. Each row is name, archive, which dictionary
// or -1 for none, and the length and CRC-32 of what it must decode to.

const _vectors = <List<Object>>[
  ['text-8-l19.zst', 'KLUv/SQIQQAAZXBzaWxvbiDye+hb', -1, 8, 4206782857],
  [
    'text-1k-l19.zst',
    'KLUv/WToAm0FABQCZGVsdGEgYWxwaGEgZ2FtbWEgZXBzaWxvbnplYnp6'
        'emV6Rqihd/3fMELCIKUHEZSElgAJvGICkQsSLEjqFgONQ/dFkqPCK9zk'
        'EARlbnSrWjFK2s9yT2FpChHFUu4LgXm6woO47CKB26c4ToOqNYIDefwu'
        'vPzgUmExJm6SCVNTUFBAP3ypt1jMN7f3rFMtiKOxEXPozGHv3le/0ZcU'
        'cgGXjO1c87aMqqcZBRCqnAj19w==',
    -1,
    1000,
    2004545584
  ],
  ['rle-1k-l19.zst', 'KLUv/WToAkUAAAh3AQDkKyAEqL9x+A==', -1, 1000, 2810990746],
  [
    'mix-1k-l1.zst',
    'KLUv/WToAmUJAIQHYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b1iemXsTOdwkkCn7oGl3NUoZXBz'
        'L6ZmWgKsJz1FQTnBkrx5+mJuLnWVxraD1ESI8yP/h3rwVTNHpVGaZ2Ft'
        'bWEgZXBze6iRLyiqR2E4IEIIqW0RRFnSwkySQvsbcWmSGY1mHMoS66IE'
        '4BVyB6LYzDpSRwHWNd076SQxQedc7Lj8tKNp/zD5mjhddbPbhYlt3Oj8'
        'sTqSGGtD7y7O2VXOH2yKuLhTNFdnfiAiNCTYlGagohV5bkXdg/daFoBu'
        'xuK3cQlVhd4w4qZ5DSaPBtlK0P5bkeaITgQxEUVChhhLg5OJOfwBMAIB'
        'joN9nRVeciokz7fUT3ECFRg9pNg=',
    -1,
    1000,
    1204304730
  ],
  [
    'mix-1k-nocheck.zst',
    'KLUv/WDoAgUJADQHYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b1heuxM53CSQKfugaXc1ShlcHMv'
        'pmZaAqwnPUVBOcGSvHn6YmJ6YW4udZXGtoPURIjzI/+HevBVM0elUZpi'
        'elaoUZcUlVMoDAcwQsPYmQcRIBRMQI2iqm7bbAaR78H55olkOatBazD9'
        'cdU7DM3GzUN7A+KIB3cqpVEZ/a8EkwIRl2ERSlLk4KDU+pQ2SFTS5b3b'
        'Cv+ieLUAaavHKYlacZfLS0E8GItU4wd/8FQVJA1pCtuPx1YIWLMaIZTk'
        'AzAg4slAeaBls2qj6hwLUpo83UFr94o31361ZRKktLdvh3t48qJc/HII'
        'LwVxVA==',
    -1,
    1000,
    1204304730
  ],
  [
    'mix-1k-l19.zst',
    'KLUv/WToAs0HAJQGYWxwaGEgemV0YSBnYW1tYmVwc2lsb25kZWwkCvmI'
        'kzvYrnOr8LN3yb6eWinsL2MqB5dg7b3sTOdwkkCn7oGl3NUoei+mZloC'
        'rCc9RUE5wZK8efpuLnWVxraD1ESI8yP/h3rwVTNHpVGaSaiBLygqp5Dl'
        'MESgFEN2EVAEBBEFhJySKNVSYzsFdOvMWHwWJQeDNy27jBjC8Yw7D9UH'
        'qjQCh9jQm0rZKi42VcCa6P1P+FHfc4/P0k4WQ2E6jBP5HT4gI5UYQj3/'
        'UwUKep0kbQAM3LMPVZhdsoLpa6SFRiUwamM1zrF3C1MwWlvme4BjPuEL'
        '1htGsc9QqBg9pNg=',
    -1,
    1000,
    1204304730
  ],
  [
    'web-dict-l3.zst',
    'KLUv/WfE3CYKtwUNCgADhw4hIyJAevxoy8lSh3mTPXy29MHSpTtESVnp'
        'as74hnckl5JFWcaXyaJg3bz7Vi1+rpqvxXw3Ed3UWloGgIT8ywOw7tS8'
        'h7eKQ0HC0hwUhjN2Sf9q89DcQ4GHav2U23Y3HB7P6jpS9FbfkAMFkSOM'
        'VdU1TOQlmzLNDikjGq8PcZqRDCSnGbiHbtuQ7Htshklfh8cUupQ9oGh6'
        'C1FqeZVzt3r0jAJ/I2w4axDsjX+EPLRliT2GvYUjK26JkOpuwZPqtNfV'
        'DRDCdKhP5CJkCkia6ummq2uMKsHxkeBwnAuerN5RKr03hru2o5i0y2Sk'
        'UGWNSiXoBXbm8bP89rVqYM2E8lUAaWxW2VeaLtRWGL1hFmMgkAagdy6r'
        'htHMCocj8r8peL/gbWPfoZT+CmPKjJgwwSIX96cAT36dDA+CRX7f0x4C'
        'UVYn',
    0,
    1719,
    1848633491
  ],
  [
    'web-dict-l19.zst',
    'KLUv/WfE3CYKtwVNCADjBg3WluswLSdbvOITW/oNlujSNQ0RZaWriTM+'
        '3smlRMnxYd28+1Ytfq6aly8y301EN7WWlkECZvxPudA4D16rHrHSjzeI'
        'j2psloKeCVZ4YFrtTh+yntq1VKzsrcScQauChuXF2IDaEcMz8fYo/3A0'
        'So/aXSxNMi9y6eo6CKJWyeOcKfOMCps2NFdDyVWBifkYsaUj38D14RZm'
        '0m8JJG0mxlcS6sdWT33VbKuSQqQH/sD9SJ5pen1KmcSfk1vV2hGDdpki'
        'Ba9sVCmjV/Gs0/2iP9rq4blMY1c2RVMpvYEDhkfxFHb5c5ZDV+ixswXh'
        'Rveuo9Cu4FM+MEMkZ3kJcPLPZGgQuUNGUWobAlFWJw==',
    0,
    1719,
    1848633491
  ],
  [
    'web-raw-l3.zst',
    'KLUv/WS3BQ0LAMJJHhqAJW7Qi0ZvRtdHN/8jA9PLpEwZJEpA37isYIKB'
        'Z1ZDRIs0tV6jJm48TiRLgqxkgMmulzA9tRcv8zhjGtFYNurjQy7CXmqt'
        'v1s21CIkZVfIL4W5mGc4fqt9fFg/SLjYqlFUO+XlZ8ehXqAgCuGVggkA'
        'QIip+cVoGF9mqFBHUhcDQMKVg+oBEsBQKIhKthjGgRdZRlba/w5LCXah'
        'gIY8AKUVnDIMGyKMwYzN6O/cbjR4RrDXdgq9tW6nw1O7YkW/1RkySxD/'
        'y665fQ0Vs7CHcFL2uAO1uKJcHUhh9tR7XMmKfk5KkumOEFknm0jqsu+R'
        'FJsgYGIy9Y+QvfIL5GnDhhDF3rHGhmjEisNEvYWCWGinhOx8MnAGJFOH'
        'haeqWTNgSIRQHV2C/GyBtsxI1PBRKx+QDAY7NSqZFqJuq9ecRjFgQpMc'
        'G4gvjGlJZn8JHcUOka/Im/ifolC6Ia1xsgVfAlFWJw==',
    1,
    1719,
    1848633491
  ],
  [
    'web-raw-l19.zst',
    'KLUv/WS3BYUJAAJJGxeATRsEAo+rAQTwlBFTk93tIPsjEQNVD8O/dCV3'
        'Dn39c563XzAOozzMxD8ukcdHzNYrHkJS1NirAQF1vZ/2PIzvdJHmBJxL'
        'tHbUIyD0aQoPm/j6blTTosvVhZKELUdxRKw5JGNYP1PMQShorwpQoDBH'
        'RmcMIERIiHPbAU+lA5qOx0KrDihiwLUPHYx9gJ4mGAs8OrQpwMcaj45d'
        'OxVlaY3iCIFb5W3gCgyew3EHz4RXcDm7HxM0iHvY4YsGSOYnIgWADkmy'
        'Dfi2Eo4tALXaPmQW7Atqn+7tkuTbj5Ecc6W/4T1DTKbQIC/NcBqoSFzc'
        '7Jj9ATcdxH5TmYEIR3hwIi3NLFc/gfKRBB2T3H5cm0NvQ+A5UUfmblK6'
        '+SpOj+/n40IzAlE+JPPBjJMqqgECUVYn',
    1,
    1719,
    1848633491
  ],
];

const _dictionaries = <String>[
  'N6Qw7MTcJgoeEOBBCsMB/////0sEoDWAAFj+r9lSpiSllNxDcTgsUwEA'
      'AAYES0nmqwsAAARgwIADCog4CXVUvMBIRBIRw0Awx3jIEAAMgKERAAAA'
      'AAAApNdhoIi6JAAAAAAAAAAAAAAAAAEAAAAEAAAACAAAAG9uIjogIm9m'
      'ZnNldCIsICJyZXN1bHQiOiA1MzM5LCAicmVnaW9uIjogImFtc3RlcmRh'
      'bSIsICJvayI6IHRydWV9CnsidmVyc2lvbiI6ICJjYWNoZSIsICJ1c2Vy'
      'X2lkIjogNzM3NSwgInJlZ2lvbiI6ICJzaW5nYXBvcmUiLCAib2siOiBm'
      'YWxzZX0KeyJzdGF0dXMiOiAiYnVja2V0IiwgInJlZ2lvbiI6IDIyNDAy'
      'LCAicmVnaW9uIjogImZyYW5rZnVydCIsICJvayI6IHRydWV9Cnsibm9k'
      'ZSI6ICJyZWdpb24iLCAicmVnaW9uIjogNzA4NzAsICJyZWdpb24iOiAi'
      'b3JlZ29uIiwgIm9rIjogdHJ1ZX0KeyJvZmZzZXQiOiAidXNlcl9pZCIs'
      'ICJwYXlsb2FkIjogMTE5MDAsICJyZWdpb24iOiAic2luZ2Fwb3JlIiwg'
      'Im9rIjogZmFsc2V9Cnsic2hhcmQiOiAib2Zmc2V0IiwgInNoYXJkIjog'
      'NTk3NjAsICJyZWdpb24iOiAic3lkbmV5IiwgIm9rIjogdHJ1ZX0KeyJl'
      'cnJvciI6ICJlcnJvciIsICJsYXRlbmN5IjogMTc0NTksICJyZWdpb24i'
      'OiAidmlyZ2luaWEiLCAib2siOiBmYWxzZX0KeyJyZXN1bHQiOiAibGF0'
      'ZW5jeSIsICJ0aW1lc3RhbXAiOiAyODQ3OCwgInJlZ2lvbiI6ICJ0b2t5'
      'byIsICJvayI6IGZhbHNlfQp7Im9mZnNldCI6ICJub2RlIiwgInZlcnNp'
      'b24iOiAzNDgyLCAicmVnaW9uIjogIm9yZWdvbiIsICJvayI6IGZhbHNl'
      'fQp7InJlZ2lvbiI6ICJzZXNzaW9uIiwgIm5vZGUiOiA2NTA0MywgInJl'
      'Z2lvbiI6ICJkdWJsaW4iLCAib2siOiB0cnVlfQp7InVzZXJfaWQiOiAi'
      'YnVja2V0IiwgInNlc3Npb24iOiA2MTg0NCwgInJlZ2lvbiI6ICJzeWRu'
      'ZXkiLCAib2siOiB0cnVlfQp7ImxhdGVuY3kiOiAibm9kZSIsICJ0aW1l'
      'c3RhbXAiOiAzNDU2MSwgInJlZ2lvbiI6ICJ2aXJnaW5pYSIsICJvayI6'
      'IGZhbHNlfQp7InRpbWVzdGFtcCI6ICJ2ZXJzaW9uIiwgInJldHJ5Ijog'
      'NDkzOTgsICJyZWdpb24iOg==',
  'eyJ1c2VyX2lkIjogInNoYXJkIiwgInJlc3VsdCI6IDk0OTQsICJyZWdp'
      'b24iOiAiZnJhbmtmdXJ0IiwgIm9rIjogZmFsc2V9CnsicmVzdWx0Ijog'
      'InJlZ2lvbiIsICJyZXN1bHQiOiAxMTI2NSwgInJlZ2lvbiI6ICJkdWJs'
      'aW4iLCAib2siOiBmYWxzZX0KeyJwYXlsb2FkIjogImxhdGVuY3kiLCAi'
      'cGF5bG9hZCI6IDcyMjI2LCAicmVnaW9uIjogImR1YmxpbiIsICJvayI6'
      'IHRydWV9CnsidGltZXN0YW1wIjogImxhdGVuY3kiLCAicmVzdWx0Ijog'
      'NzU2NDIsICJyZWdpb24iOiAiZHVibGluIiwgIm9rIjogdHJ1ZX0KeyJs'
      'YXRlbmN5IjogInJlc3VsdCIsICJ1c2VyX2lkIjogMzc5NTksICJyZWdp'
      'b24iOiAiZHVibGluIiwgIm9rIjogdHJ1ZX0KeyJ0aW1lc3RhbXAiOiAi'
      'cmV0cnkiLCAic2Vzc2lvbiI6IDEzNQ==',
];

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
  for (final count in [0, 3, 4, 6, 8]) {
    test('4 Huffman streams check literal count of $count', () {
      final segment = (count + 3) >> 2;
      final tail = count - 3 * segment;
      // Each zero literal consumes one bit from a two-symbol Huffman table
      final frame = Uint8List.fromList([
        40,
        181,
        47,
        253,
        0,
        0,
        133,
        0,
        0,
        6 | (count << 4),
        0,
        3,
        128,
        16,
        1,
        0,
        1,
        0,
        1,
        0,
        1 << segment,
        1 << segment,
        1 << segment,
        1 << tail,
        0,
      ]);
      if (count < 6) {
        expect(
            () => ZstdDecoder()
                .decodeBytes(frame, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      } else {
        expect(
            ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            List<int>.filled(count, 0));
      }
    });
  }

  for (final marker in [0, 1, 2, 4, 128, 255]) {
    test('4 Huffman streams check empty tail marker $marker', () {
      // The first three streams emit two literals each, leaving the fourth empty
      final frame = Uint8List.fromList([
        40,
        181,
        47,
        253,
        0,
        0,
        133,
        0,
        0,
        102,
        0,
        3,
        128,
        16,
        1,
        0,
        1,
        0,
        1,
        0,
        4,
        4,
        4,
        marker,
        0,
      ]);
      if (marker == 1) {
        expect(
            ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            List<int>.filled(6, 0));
      } else {
        expect(
            () => ZstdDecoder()
                .decodeBytes(frame, verify: true, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      }
    });
  }

  test(
      'streamed matches stay correct after 1 KiB window wraps on every platform',
      () {
    final encoded = base64Decode(
        'KLUv/QQAZAAAKGFiY2RlAQD4URUtTAAAEGVhAQD7K4AFTAAAEGRlAQD7K4AF'
        'TAAAEGNkAQD7K4AFTAAAEGJjAQD7K4AFTAAAEGFiAQD7K4AFTAAAEGVhAQD7'
        'K4AFTAAAEGRlAQD7K4AFTAAAEGNkAQD7K4AFTAAAEGJjAQD7K4AFTAAAEGFi'
        'AQD7K4AFTAAAEGVhAQD7K4AFTAAAEGRlAQD7K4AFTAAAEGNkAQD7K4AFRQAA'
        'CGIBAJQqIATVo9ya');
    final source = List<int>.generate(15000, (i) => 97 + i % 5);
    expect(ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true),
        source);
    final output = OutputMemoryStream();
    ZstdDecoder().decodeStream(InputMemoryStream(encoded), output,
        verify: true, throwOnError: true);
    expect(output.getBytes(), source);
  });

  test('highest bit works for every exact integer width', () {
    const native = bool.fromEnvironment('dart.library.isolate');
    final maximumBit = native ? 62 : 52;
    var power = 1;
    for (var bit = 0; bit <= maximumBit; bit++) {
      expect(zstdHighestBitFast(power), bit);
      if (bit > 0) {
        expect(zstdHighestBitFast(power - 1), bit - 1);
        expect(zstdHighestBitFast(power + 1), bit);
      }
      power *= 2;
    }
  });

  final dictionaries = [
    for (final d in _dictionaries) ZstdDictionary(base64.decode(d))
  ];

  for (final vector in _vectors) {
    final name = vector[0] as String;
    final bytes = base64.decode(vector[1] as String);
    final which = vector[2] as int;
    final length = vector[3] as int;
    final crc = vector[4] as int;

    test('$name decodes', () {
      final decoder = which < 0
          ? ZstdDecoder()
          : ZstdDecoder.withDictionary(dictionaries[which]);
      final decoded =
          decoder.decodeBytes(bytes, verify: true, throwOnError: true);
      expect(decoded.length, length);
      expect(getCrc32(decoded), crc);
    });
  }

  test('damaged byte throws on checksum mismatch', () {
    final bytes = Uint8List.fromList(base64.decode(_vectors[5][1] as String));
    bytes[bytes.length - 1] ^= 0x20;
    expect(
        () =>
            ZstdDecoder().decodeBytes(bytes, verify: true, throwOnError: true),
        throwsA(isA<ArchiveChecksumException>()));
  });

  test(
      'match copy beyond block output throws ArchiveException on this platform',
      () {
    final bytes = Uint8List.fromList(base64.decode(_vectors[1][1] as String));
    bytes[46] ^= 0x80;
    expect(ZstdDecoder().decodeBytes(bytes), isEmpty);
    expect(
        ZstdDecoder()
            .decodeStream(InputMemoryStream(bytes), OutputMemoryStream()),
        isFalse);
    for (final (verify, throwOnError) in [(true, true), (false, true)]) {
      expect(
          () => ZstdDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError),
          throwsA(isA<ArchiveException>()),
          reason: 'verify $verify, throwOnError $throwOnError');
    }
  });

  test('XXH64 matches reference on this platform', () {
    final data = Uint8List(200);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 31 + 7) & 0xff;
    }
    final hash = Xxh64();
    hash.update(data, 0, data.length);
    expect(hash.digestHigh, 0x95d9a0c9);
    expect(hash.digestLow, 0x77b4b6fb);
  });

  test('XXH64 accepts seed above 32 bits on this platform', () {
    final data = Uint8List(100);
    for (var i = 0; i < data.length; i++) {
      data[i] = (i * 31) & 0xff;
    }
    const cases = [
      [4294967301, 100, 0x2e8ad948, 0x73e51d5c],
      [4294967301, 0, 0x3bfea580, 0xce35fa56],
      [-1, 100, 0x78016a97, 0x2d89b704],
      [-1, 0, 0x298f4c84, 0xb24f5380],
      [-12345, 100, 0x1c0c124f, 0xe3e83d25],
    ];
    for (final c in cases) {
      final hash = Xxh64(c[0])..update(data, 0, c[1]);
      expect([hash.digestHigh, hash.digestLow], [c[2], c[3]],
          reason: 'seed ${c[0]} length ${c[1]}');
    }
  });

  group('zstd on every platform', () {
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
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(data), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveChecksumException>()));
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

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// This file deliberately avoids dart:io so that it can be run on the web
// targets as well as the VM, with `dart test -p chrome` or `-p node`. The
// thing being guarded here is a per platform choice, so a test that only ever
// runs on the VM would not guard much.

// 'hello\n' compressed with xz, small enough to embed. Decoding it exercises
// the range decoder that the platform selected.
const _helloXz =
    '/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQAFaGVsbG8KAAAApWCX8ZT2/eAAAR4GwS'
    '+kHR+2830BAAAAAARZWg==';

// The text below four times over, compressed with `xz --check=none -6`. A
// stream written with no check carries no checksum, so the state the range
// decoder is left in is the only thing that can say its data was damaged.
const _nocheckXz =
    '/Td6WFoAAAD/EtlBBMA4sAEhARYAAAAAAAAAABNSxW/gAK8AMF0AOhoIznbH5enWBz'
    'TD0Q6/zlXhqr3g5I+YAd2N5QdUnmUlXyc6an6000kA/X0vp5AAAAABTLABAAAAu3G0'
    'E6gACvwCAAAAAABZWg==';

const _nocheckText = 'the quick brown fox jumps over the lazy dog ';

void main() {
  group('lzma range decoder', () {
    test('picks the implementation this platform can run', () {
      // An int is a JavaScript number exactly where 1 and 1.0 are identical,
      // and that is exactly where the branchless 64 bit implementation gives
      // wrong answers rather than slow ones. Everywhere else it is both
      // correct and faster, so the two have to line up.
      //
      // The conditional export in range_decoder.dart is easy to get subtly
      // wrong. Selecting the branching implementation on wasm breaks nothing
      // visible, it only gives up about a sixth of the decoding speed, which
      // is exactly the kind of regression that survives a green test suite.
      final jsNumbers = identical(1, 1.0);
      expect(rangeDecoderImplementation, jsNumbers ? 'web' : 'native');
    });

    test('decodes the same bytes whichever implementation was selected', () {
      final compressed = base64.decode(_helloXz);
      expect(
          XZDecoder().decodeBytes(compressed), equals(utf8.encode('hello\n')));
    });

    test('rejects a chunk it did not finish decoding', () {
      // The archive is sound, and what it holds is asserted rather than taken
      // on trust.
      expect(XZDecoder().decodeBytes(base64.decode(_nocheckXz), verify: true),
          equals(utf8.encode(_nocheckText * 4)));

      // Flipping byte 84 leaves every length in the archive agreeing while 124
      // of the 176 decoded bytes come out wrong, so with no checksum to fall
      // back on nothing but the decoder's own final state is left to catch it.
      // xz calls the same archive corrupt. Which arithmetic reaches that state
      // is what the two implementations disagree about, so this belongs here
      // rather than beside the other xz archives, which the web cannot read.
      final damaged = base64.decode(_nocheckXz);
      damaged[84] ^= 0xFF;
      expect(
          () => XZDecoder()
              .decodeBytes(damaged, verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()));
    });
  });
}

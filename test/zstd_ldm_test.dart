import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_ldm.dart';
import 'package:test/test.dart';

/// The reference turns the long distance matcher on only for a window of
/// twenty seven bits, which needs a source of a hundred and twenty eight
/// megabytes to select. These build it directly instead, on a source small
/// enough to keep in a test but laid out so the matcher has something to find
ZstdLdm _matcher() => ZstdLdm.forParams(8, 27)!;

/// Text with a long stretch repeated far enough back that only a matcher with
/// this reach finds it again
Uint8List _repeatedFar(int gap, int run) {
  final head = Uint8List(run);
  for (var at = 0; at < run; at++) {
    head[at] = 0x20 + ((at * 7 + (at >> 4)) % 90);
  }
  final filler = Uint8List(gap);
  for (var at = 0; at < gap; at++) {
    filler[at] = 0x20 + ((at * 2654435761) % 90);
  }
  final out = Uint8List(run + gap + run);
  out.setRange(0, run, head);
  out.setRange(run, run + gap, filler);
  out.setRange(run + gap, run + gap + run, head);
  return out;
}

void main() {
  group('zstd long distance matcher', () {
    test('enabled only for widest window, as in reference', () {
      expect(ZstdLdm.forParams(8, 26), isNull);
      expect(ZstdLdm.forParams(8, 27), isNotNull);
      expect(ZstdLdm.forParams(5, 27), isNull);
      // The deepest search halves the match it will take
      final deep = ZstdLdm.forParams(9, 27)!;
      final shallow = ZstdLdm.forParams(7, 27)!;
      expect(deep.minMatch, lessThan(shallow.minMatch));
      expect(deep.windowLog, 27);
    });

    test('sequence capacity matches requested block size', () {
      final ldm = _matcher();
      expect(ldm.capacityFor(1 << 17), (1 << 17) ~/ ldm.minMatch + 1);
      expect(ldm.capacityFor(0), 1);
    });

    test(
        'strategies 6 to 9 give long distance minMatch null, 64, 32, 32 as reference',
        () {
      expect(
          [6, 7, 8, 9]
              .map((strategy) => ZstdLdm.forParams(strategy, 27)?.minMatch),
          [null, 64, 32, 32]);
    });

    test('run repeated far back is found', () {
      final ldm = _matcher();
      final src = _repeatedFar(1 << 20, 1 << 12);
      final view = ByteData.sublistView(src);
      final out = ZstdLdmSequences(ldm.capacityFor(src.length));
      ldm.generate(src, view, 0, src.length, out);
      expect(out.size, greaterThan(0));
      var found = false;
      for (var n = 0; n < out.size; n++) {
        if (out.matchLength[n] >= ldm.minMatch && out.offset[n] >= 1 << 20) {
          found = true;
        }
      }
      expect(found, isTrue, reason: 'no match reached back over the filler');
    });

    test('source without repeats gives no sequences', () {
      final ldm = _matcher();
      final src = Uint8List(1 << 16);
      for (var at = 0; at < src.length; at++) {
        src[at] = (at * 1103515245 + 12345) >> 11 & 0xff;
      }
      final out = ZstdLdmSequences(ldm.capacityFor(src.length));
      ldm.generate(src, ByteData.sublistView(src), 0, src.length, out);
      for (var n = 0; n < out.size; n++) {
        expect(out.matchLength[n], greaterThanOrEqualTo(ldm.minMatch));
      }
    });

    test('block shorter than minimum match is skipped', () {
      final ldm = _matcher();
      final src = Uint8List(4);
      final out = ZstdLdmSequences(ldm.capacityFor(1 << 17));
      ldm.generate(src, ByteData.sublistView(src), 0, src.length, out);
      expect(out.size, 0);
    });

    // What a dictionary put in the table is reachable from the first block
    test('filled table finds matches in data that filled it', () {
      final ldm = _matcher();
      final src = _repeatedFar(1 << 20, 1 << 12);
      final half = (1 << 12) + (1 << 20);
      ldm.fill(src, 0, half);
      final out = ZstdLdmSequences(ldm.capacityFor(src.length));
      ldm.generate(src, ByteData.sublistView(src), half, src.length, out);
      expect(out.size, greaterThan(0));
    });

    // `slide` is what lets a streamed frame drop the front of its buffer, and
    // a position that fell off the front has to read as never filled
    test('slide moves kept positions and drops others', () {
      final ldm = _matcher();
      final src = _repeatedFar(1 << 20, 1 << 12);
      final view = ByteData.sublistView(src);
      final before = ZstdLdmSequences(ldm.capacityFor(src.length));
      ldm.generate(src, view, 0, src.length, before);
      expect(before.size, greaterThan(0));

      final slid = _matcher();
      final delta = 1 << 11;
      final moved = Uint8List(src.length + delta);
      moved.setRange(delta, delta + src.length, src);
      slid.generate(moved, ByteData.sublistView(moved), delta, moved.length,
          ZstdLdmSequences(slid.capacityFor(moved.length)));
      slid.slide(delta);

      // Everything the slid table holds now describes the unshifted source, so
      // a fresh pass over it finds what the unshifted pass found
      final after = ZstdLdmSequences(slid.capacityFor(src.length));
      slid.generate(src, view, 0, src.length, after);
      expect(after.size, greaterThan(0));
    });

    test('slide past all data leaves no match candidates', () {
      final src = _repeatedFar(1 << 20, 1 << 12);
      final view = ByteData.sublistView(src);
      final tail = (1 << 12) + (1 << 20);

      final kept = _matcher()..fill(src, 0, tail);
      final reached = ZstdLdmSequences(kept.capacityFor(src.length));
      kept.generate(src, view, tail, src.length, reached);
      expect(reached.size, greaterThan(0));

      var reach = 0;
      for (var n = 0; n < reached.size; n++) {
        if (reached.offset[n] > reach) {
          reach = reached.offset[n];
        }
      }
      expect(reach, greaterThanOrEqualTo(1 << 20));

      final dropped = _matcher()..fill(src, 0, tail);
      dropped.slide(1 << 30);
      final near = ZstdLdmSequences(dropped.capacityFor(src.length));
      dropped.generate(src, view, tail, src.length, near);
      for (var n = 0; n < near.size; n++) {
        expect(near.offset[n], lessThan(src.length - tail),
            reason: 'a dropped position was still reachable');
      }
    });
  });
}

import 'dart:math' as math;
import 'dart:typed_data';

// The inputs the zstd fixtures were compressed from, so that only compressed
// data needs storing. These must produce exactly what the functions of the
// same name in test/_data/zstd/gen_fixtures.js produce, and use only 32 bit
// integer operations so that they do on the web too.

int Function() _rng(int seed) {
  var s = seed & 0xffffffff;
  return () {
    s ^= (s << 13) & 0xffffffff;
    s ^= s >>> 17;
    s ^= (s << 5) & 0xffffffff;
    return s;
  };
}

/// A mix of skewed text, matches at short to long distances, byte runs and
/// random bytes.
Uint8List synth(int n, int seed) {
  final next = _rng(seed);
  final b = Uint8List(n);
  var i = 0;
  while (i < n) {
    final r = next() % 100;
    if (r < 45 && i > 0) {
      final k = next() % 4;
      final limit = k == 3 ? i : math.min(i, const [16, 1000, 60000][k]);
      final d = 1 + next() % limit;
      final len = 3 + next() % (k == 0 ? 50 : 30);
      for (var j = 0; j < len && i < n; j++, i++) {
        b[i] = b[i - d];
      }
    } else if (r < 85) {
      final len = 1 + next() % 20;
      for (var j = 0; j < len && i < n; j++, i++) {
        b[i] = 97 + ((next() % 26) * (next() % 26)) ~/ 26;
      }
    } else if (r < 95) {
      final v = next() & 0xff;
      final len = 1 + next() % 300;
      for (var j = 0; j < len && i < n; j++, i++) {
        b[i] = v;
      }
    } else {
      final len = 1 + next() % 100;
      for (var j = 0; j < len && i < n; j++, i++) {
        b[i] = next() & 0xff;
      }
    }
  }
  return b;
}

/// Copies of 2000 random bytes with a 'Z' inserted every so often.
Uint8List rleLiterals(int n, int seed) {
  final next = _rng(seed);
  final r = Uint8List(2000);
  for (var i = 0; i < 2000; i++) {
    r[i] = next() & 0xff;
  }
  final b = Uint8List(n);
  var j = 0;
  for (var i = 0; i < n; i++) {
    if (i >= 2000 && next() % 200 == 0) {
      b[i] = 90;
    } else {
      b[i] = r[j++ % 2000];
    }
  }
  return b;
}

/// Sixteen symbols with skewed frequencies.
Uint8List nibbles(int n, int seed) {
  final next = _rng(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = ((next() % 16) * (next() % 16)) >> 4;
  }
  return b;
}

Uint8List randomBytes(int n, int seed) {
  final next = _rng(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = next() & 0xff;
  }
  return b;
}

Uint8List concat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

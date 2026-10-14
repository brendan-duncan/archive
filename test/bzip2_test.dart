import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('ignores selectors past the most a block can use', () {
    // Some encoders write more than the 18002 selectors a block can use.
    // libbzip2 reads the rest and ignores them; this used to be reported as
    // a truncated stream.
    final data = Uint8List.fromList(List.generate(1000, (i) => i % 7));
    final compressed = BZip2Encoder().encodeBytes(data);

    final bits = [
      for (final byte in compressed)
        for (var i = 7; i >= 0; i--) (byte >> i) & 1
    ];
    int read(int at, int n) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        v = (v << 1) | bits[at + i];
      }
      return v;
    }

    // Stream header, block magic, block CRC, randomised bit, origPtr.
    var at = 32 + 48 + 32 + 1 + 24;
    final inUse16 = read(at, 16);
    at += 16;
    for (var i = 0; i < 16; i++) {
      if (inUse16 & (0x8000 >> i) != 0) {
        at += 16;
      }
    }
    final groups = read(at, 3);
    at += 3;
    final selectors = read(at, 15);
    expect(groups, greaterThanOrEqualTo(2));
    // Declare 18010, adding zeros, which repeat the selector before.
    const declared = 18010;
    for (var i = 0; i < 15; i++) {
      bits[at + i] = (declared >> (14 - i)) & 1;
    }
    at += 15;
    for (var i = 0; i < selectors; i++) {
      while (bits[at++] == 1) {}
    }
    bits.insertAll(at, List.filled(declared - selectors, 0));

    final bytes = Uint8List((bits.length + 7) >> 3);
    for (var i = 0; i < bits.length; i++) {
      bytes[i >> 3] |= bits[i] << (7 - (i & 7));
    }
    expect(BZip2Decoder().decodeBytes(bytes, verify: true), equals(data));
  });

  test('decode', testOn: 'vm', () {
    final orig = io.File(p.join('test/_data/bzip2/test.bz2')).readAsBytesSync();

    BZip2Decoder().decodeBytes(orig, verify: true);
  });

  test('encode', testOn: 'vm', () {
    final file = io.File(p.join('test/_data/cat.jpg')).readAsBytesSync();

    final compressed = BZip2Encoder().encodeBytes(file);

    final d2 = BZip2Decoder().decodeBytes(compressed, verify: true);

    expect(d2.length, equals(file.length));
    for (var i = 0, len = d2.length; i < len; ++i) {
      expect(d2[i], equals(file[i]));
    }
  });

  test('encode with block size outside 1..9 throws ArgumentError', () {
    expect(() => BZip2Encoder().encodeBytes([1, 2, 3], blockSize100k: 10),
        throwsA(isA<ArgumentError>()));
  });

  // After a stream bzip2 1.0.8 reads BZh and a digit from 1 to 9. If a byte
  // differs, bzip2 ignores the rest as trailing garbage and exits 0
  test('trailing bytes that start no stream are ignored by every decode path',
      () async {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final stream = BZip2Encoder().encodeBytes(data);
    for (final tail in [
      [0x41, 0x41, 0x41],
      [0x42, 0x41],
      [0x42, 0x5A, 0x68, 0x30],
      [0x42, 0x5A, 0x68, 0x78],
    ]) {
      final archive = Uint8List.fromList([...stream, ...tail]);
      final output = OutputMemoryStream();
      expect(
          BZip2Decoder()
              .decodeStream(InputMemoryStream(archive), output, verify: true),
          isTrue,
          reason: 'decodeStream, tail $tail');
      expect(output.getBytes(), data);
      expect(BZip2Decoder().decodeBytes(archive, verify: true), data,
          reason: 'decodeBytes, tail $tail');
      expect(bzip2Codec.decode(archive), data, reason: 'converter, tail $tail');
      // One byte at a time. The converter gets the tail in pieces
      final pieces = await Stream.fromIterable([
        for (final byte in archive) [byte]
      ]).transform(bzip2Codec.decoder).expand((piece) => piece).toList();
      expect(pieces, data, reason: 'converter by bytes, tail $tail');
    }
  });

  // The input ends inside BZh and the digit. bzip2 1.0.8 exits 2 on it
  test('trailing bytes ending inside stream signature fail every decode path',
      () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final stream = BZip2Encoder().encodeBytes(data);
    for (final tail in [
      [0x42],
      [0x42, 0x5A],
      [0x42, 0x5A, 0x68],
      [0x42, 0x5A, 0x68, 0x39],
    ]) {
      final archive = Uint8List.fromList([...stream, ...tail]);
      expect(
          BZip2Decoder()
              .decodeStream(InputMemoryStream(archive), OutputMemoryStream()),
          isFalse,
          reason: 'decodeStream, tail $tail');
      expect(
          () => BZip2Decoder().decodeStream(
              InputMemoryStream(archive), OutputMemoryStream(),
              verify: true, throwOnError: true),
          throwsA(isA<ArchiveException>()),
          reason: 'decodeStream with verify, tail $tail');
      expect(() => bzip2Codec.decode(archive), throwsA(isA<ArchiveException>()),
          reason: 'converter, tail $tail');
    }
  });

  test('truncated archive fails with memory and file input streams',
      testOn: 'vm', () async {
    // A file reads zeros past its end and memory throws, so the bit reader
    // stops at the end itself, or the verdict depends on the stream given
    final source = Uint8List(400000);
    for (var i = 0; i < source.length; i++) {
      source[i] = (i * 17 + (i >> 5)) & 0xff;
    }
    final whole = BZip2Encoder().encodeBytes(source, blockSize100k: 1);
    final dir = io.Directory.systemTemp.createTempSync('bz_cut');
    try {
      for (var cut = 4; cut < whole.length; cut += whole.length ~/ 12) {
        final bytes = Uint8List.sublistView(whole, 0, cut);
        final file = io.File('${dir.path}/cut.bz2')..writeAsBytesSync(bytes);

        expect(
            BZip2Decoder()
                .decodeStream(InputMemoryStream(bytes), OutputMemoryStream()),
            isFalse,
            reason: 'memory, cut at $cut');
        final input = InputFileStream(file.path);
        expect(
            BZip2Decoder().decodeStream(input, OutputMemoryStream()), isFalse,
            reason: 'file, cut at $cut');
        input.closeSync();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('wrong block CRC throws only with verify and throwOnError', () async {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final bad = Uint8List.fromList(BZip2Encoder().encodeBytes(data));
    bad[10] ^= 0xff;
    expect(BZip2Decoder().decodeBytes(bad), data);
    expect(BZip2Decoder().decodeBytes(bad, throwOnError: true), data);
    expect(BZip2Decoder().decodeBytes(bad, verify: true), data);
    expect(
        () => BZip2Decoder().decodeBytes(bad, verify: true, throwOnError: true),
        throwsA(isA<ArchiveChecksumException>()));
    await expectLater(
        Stream<List<int>>.value(bad).transform(bzip2Codec.decoder),
        emitsThrough(emitsError(isA<ArchiveChecksumException>())));
  });

  test(
      'damaged or truncated data throws with verify or throwOnError, not without',
      () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final whole = BZip2Encoder().encodeBytes(data);
    for (final bad in [
      Uint8List.sublistView(whole, 0, whole.length ~/ 2),
      Uint8List.fromList([1, 2, 3, 4, 5]),
    ]) {
      expect(
          BZip2Decoder()
              .decodeStream(InputMemoryStream(bad), OutputMemoryStream()),
          isFalse);
      for (final (verify, throwOnError) in [(true, true), (false, true)]) {
        expect(
            () => BZip2Decoder()
                .decodeBytes(bad, verify: verify, throwOnError: throwOnError),
            throwsA(allOf(isA<ArchiveException>(),
                isNot(isA<ArchiveChecksumException>()))),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    }
  });

  test('zip entry with damaged bzip2 data throws ArchiveException', () {
    final source = Uint8List(200000);
    for (var i = 0; i < source.length; i++) {
      source[i] = (i * 29 + (i >> 4)) & 0xff;
    }
    final archive = Archive()
      ..add(ArchiveFile.bytes('a.bin', source)
        ..compression = CompressionType.bzip2);
    final zip = ZipEncoder().encodeBytes(archive);
    final bad = Uint8List.fromList(zip);
    for (var i = 120; i < 400 && i < bad.length; i++) {
      bad[i] = bad[i] ^ 0xff;
    }

    expect(ZipDecoder().decodeBytes(bad).files.single.readBytes(), isEmpty);
    final entry =
        ZipDecoder().decodeBytes(bad, throwOnError: true).files.single;
    expect(entry.readBytes, throwsA(isA<ArchiveException>()));
  });

  test('stream header with block size 0 fails every decode path', () async {
    final good = BZip2Encoder().encodeBytes([1, 2, 3]);
    final bad = Uint8List.fromList(good)..[3] = 0x30;

    expect(BZip2Decoder().decodeBytes(bad), isEmpty);
    expect(
        () => BZip2Decoder().decodeBytes(bad, verify: true, throwOnError: true),
        throwsA(isA<ArchiveException>()));
    expect(
        BZip2Decoder()
            .decodeStream(InputMemoryStream(bad), OutputMemoryStream()),
        isFalse);
    await expectLater(
        Stream<List<int>>.fromIterable([bad]).transform(bzip2Codec.decoder),
        emitsError(isA<ArchiveException>()));
  });

  // bzip2 1.0.8 reads selectors past 18002 and ignores them
  test('block with more than 18001 selectors decodes, as bzip2 1.0.8 does', () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final archive =
        _withExtraSelectors(BZip2Encoder().encodeBytes(data), 18008);
    final output = OutputMemoryStream();
    expect(
        BZip2Decoder()
            .decodeStream(InputMemoryStream(archive), output, verify: true),
        isTrue);
    expect(output.getBytes(), data);
    expect(bzip2Codec.decode(archive), data);
  });

  test('endStream writes block left open by addByte', () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
    final encoder = BZip2Encoder()..beginStream(output);
    for (final byte in data) {
      if (encoder.addByte(byte)) {
        encoder.endBlock();
      }
    }
    encoder.endStream();
    expect(output.getBytes(), BZip2Encoder().encodeBytes(data));
    expect(BZip2Decoder().decodeBytes(output.getBytes(), verify: true), data);
  });

  test('randomised block decodes to original data on every path', () async {
    final data = Uint8List.fromList(
        List.generate(20000, (i) => (i ~/ 3 * 37 + (i >> 5) * 11) % 128 * 2));
    final archive = _randomised(data);
    expect(BZip2Decoder().decodeBytes(archive, verify: true), data);
    final output = OutputMemoryStream();
    expect(
        BZip2Decoder()
            .decodeStream(InputMemoryStream(archive), output, verify: true),
        isTrue);
    expect(output.getBytes(), data);
    expect(bzip2Codec.decode(archive), data);
  });

  test('blocks above 16384 symbols decode on every path', () {
    var seed = 1;
    final noise = List.generate(60000, (_) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed >> 16 & 0xff;
    });
    final runs = [for (var i = 0; i < 400; i++) ...List.filled(400, i % 7)];
    for (final data in [
      Uint8List.fromList(noise),
      Uint8List.fromList(runs),
      Uint8List.fromList([...noise, ...runs, ...noise, ...runs]),
    ]) {
      for (final blockSize100k in [1, 9]) {
        final archive =
            BZip2Encoder().encodeBytes(data, blockSize100k: blockSize100k);
        final reason = '${data.length} bytes, blockSize100k $blockSize100k';
        expect(BZip2Decoder().decodeBytes(archive, verify: true), data,
            reason: reason);
        final output = OutputMemoryStream();
        expect(
            BZip2Decoder()
                .decodeStream(InputMemoryStream(archive), output, verify: true),
            isTrue,
            reason: reason);
        expect(output.getBytes(), data, reason: reason);
        expect(bzip2Codec.decode(archive), data, reason: reason);
      }
    }
  });
}

Uint8List _randomised(Uint8List data) {
  final masked = Uint8List.fromList(data);
  var toGo = 0;
  var next = 0;
  for (var i = 0; i < masked.length; i++) {
    if (toGo == 0) {
      toGo = BZip2Decoder.bz2RNums[next];
      next = (next + 1) % BZip2Decoder.bz2RNums.length;
    }
    toGo--;
    if (toGo == 1) {
      masked[i] ^= 1;
    }
  }
  var crc = BZip2.initialCrc;
  for (final byte in data) {
    crc = BZip2.updateCrc(byte, crc);
  }
  crc = BZip2.finalizeCrc(crc);
  final stream = BZip2Encoder().encodeBytes(masked);
  final reader = _BitReader(stream);
  var end = stream.length * 8 - 80;
  while (true) {
    reader.at = end;
    if (reader.read(48) == 0x177245385090) {
      break;
    }
    end--;
  }
  reader.at = 0;
  final writer = _BitWriter();
  void copy(int bits) => writer.write(reader.read(bits), bits);
  copy(32);
  copy(48);
  reader.read(33);
  writer.write(crc, 32);
  writer.write(1, 1);
  while (reader.at < end) {
    copy(1);
  }
  copy(48);
  reader.read(32);
  writer.write(crc, 32);
  while (reader.at < stream.length * 8) {
    copy(1);
  }
  return writer.bytes;
}

Uint8List _withExtraSelectors(Uint8List stream, int extra) {
  final reader = _BitReader(stream);
  final writer = _BitWriter();
  void copy(int bits) => writer.write(reader.read(bits), bits);
  copy(32);
  copy(48);
  copy(32);
  copy(1);
  copy(24);
  final used = reader.read(16);
  writer.write(used, 16);
  for (var i = 0; i < 16; i++) {
    if (used & (0x8000 >> i) != 0) {
      copy(16);
    }
  }
  copy(3);
  final count = reader.read(15);
  writer.write(count + extra, 15);
  for (var i = 0; i < count; i++) {
    var bit = 1;
    while (bit != 0) {
      bit = reader.read(1);
      writer.write(bit, 1);
    }
  }
  writer.write(0, extra);
  while (reader.at < stream.length * 8) {
    copy(1);
  }
  return writer.bytes;
}

class _BitReader {
  final Uint8List _bytes;
  var at = 0;

  _BitReader(this._bytes);

  int read(int bits) {
    var value = 0;
    for (var i = 0; i < bits; i++) {
      value = value * 2 + ((_bytes[at >> 3] >> (7 - (at & 7))) & 1);
      at++;
    }
    return value;
  }
}

class _BitWriter {
  final _out = <int>[];
  var _byte = 0;
  var _filled = 0;

  void write(int value, int bits) {
    final digits = List<int>.filled(bits, 0);
    var rest = value;
    for (var i = 0; i < bits; i++) {
      digits[i] = rest % 2;
      rest ~/= 2;
    }
    for (var i = bits - 1; i >= 0; i--) {
      _byte = (_byte << 1) | digits[i];
      if (++_filled == 8) {
        _out.add(_byte);
        _byte = 0;
        _filled = 0;
      }
    }
  }

  Uint8List get bytes =>
      Uint8List.fromList([..._out, if (_filled > 0) _byte << (8 - _filled)]);
}

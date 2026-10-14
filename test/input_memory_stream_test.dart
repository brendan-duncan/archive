import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

final _maxInt = -1 >>> 1;

void main() {
  group('InputStreamMemory', () {
    test('negative offset throws RangeError, never reads before view', () {
      final backing = Uint8List.fromList([11, 22, 33, 44]);
      final view = Uint8List.sublistView(backing, 1, 3);
      for (final bytes in [
        <int>[22, 33],
        view
      ]) {
        expect(() => InputMemoryStream(bytes, offset: -1, length: 1),
            throwsRangeError);
        expect(() => InputMemoryStream(bytes, offset: -1), throwsRangeError);
        final input = InputMemoryStream(bytes);
        expect(() => input.subset(position: -1, length: 1), throwsRangeError);
        expect(() => input.peekBytes(1, offset: -1), throwsRangeError);
        expect(input.position, 0);
        input.skip(1);
        expect(input.peekBytes(1, offset: -1).toUint8List(), [22]);
        expect(input.position, 1);
        expect(input.subset(position: 2).isEOS, isTrue);
      }
    });

    test(
        'toUint8List at negative position throws RangeError, never reads before view',
        () {
      final backing = Uint8List.fromList([11, 22, 33, 44]);
      final input = InputMemoryStream(Uint8List.sublistView(backing, 1, 3));
      input.setPosition(-1);
      expect(input.toUint8List, throwsRangeError);
      expect(input.position, -1);
      input.setPosition(1);
      final bytes = input.toUint8List();
      expect(bytes, [33]);
      bytes[0] = 55;
      expect(backing, [11, 22, 55, 44]);
      expect(input.position, 1);
    });

    test('length near 2^63 is clamped to buffer', () {
      final input =
          InputMemoryStream(Uint8List(10), offset: 2, length: _maxInt);
      expect(input.length, 8);
      final whole = InputMemoryStream(Uint8List(10))..skip(3);
      expect(whole.readBytes(_maxInt).length, 7);
    }, testOn: 'vm');

    test('skip and rewind near 2^63 stay inside stream bounds', () {
      final input = InputMemoryStream([11, 22, 33]);
      final maximum = _maxInt;
      final minimum = -maximum - 1;
      input.setPosition(1);
      input.skip(maximum);
      expect(input.position, 3);
      expect(input.isEOS, isTrue);
      input.setPosition(1);
      input.rewind(minimum);
      expect(input.position, 3);
      input.rewind(maximum);
      expect(input.position, 0);
      input.skip(minimum);
      expect(input.position, 0);
      input.skip(2);
      input.skip(-1);
      expect(input.position, 1);
      input.rewind(-1);
      expect(input.position, 2);
      input.rewind();
      expect(input.readByte(), 22);
    }, testOn: 'vm');

    test('readInto count near 2^63 stops at remaining bytes', () {
      final input = InputMemoryStream([1, 2, 3, 4])..skip(1);
      final bytes = Uint8List(5)..fillRange(0, 5, 9);
      expect(input.readInto(bytes, 1, _maxInt), 3);
      expect(bytes, [9, 2, 3, 4, 9]);
      expect(input.position, 4);
      expect(input.readInto(bytes, 0, _maxInt), 0);
    }, testOn: 'vm');

    test('viewBytes count near 2^63 returns null and keeps position', () {
      final input = InputMemoryStream([1, 2, 3, 4])..skip(1);
      expect(input.viewBytes(_maxInt), isNull);
      expect(input.position, 1);
      expect(input.viewBytes(3), [2, 3, 4]);
      expect(input.position, 4);
    }, testOn: 'vm');

    test('empty', () {
      final input = InputMemoryStream.empty();
      expect(input.length, equals(0));
      expect(input.isEOS, equals(true));
    });

    test('totalLength', () {
      final input = InputMemoryStream.fromList(List.generate(10, (i) => i));
      input.skip(4);
      expect(input.length, 6);
      expect(input.totalLength, 10);
      final sub = input.subset(position: 2, length: 5)..skip(3);
      expect(sub.totalLength, 5);
      expect(InputMemoryStream.empty().totalLength, 0);
    });

    test('readByte', () async {
      const data = [0xaa, 0xbb, 0xcc];
      final input = InputMemoryStream.fromList(data);
      expect(input.length, equals(3));
      expect(input.readByte(), equals(0xaa));
      expect(input.readByte(), equals(0xbb));
      expect(input.readByte(), equals(0xcc));
      expect(input.isEOS, equals(true));
    });

    test('peakBytes', () async {
      const data = [0xaa, 0xbb, 0xcc];
      final input = InputMemoryStream.fromList(data);
      expect(input.readByte(), equals(0xaa));

      final bytes = input.peekBytes(2).toUint8List();
      expect(bytes[0], equals(0xbb));
      expect(bytes[1], equals(0xcc));
      expect(input.readByte(), equals(0xbb));
      expect(input.readByte(), equals(0xcc));
      expect(input.isEOS, equals(true));
    });

    test('skip', () async {
      const data = [0xaa, 0xbb, 0xcc];
      final input = InputMemoryStream.fromList(data);
      expect(input.length, equals(3));
      expect(input.readByte(), equals(0xaa));
      input.skip(1);
      expect(input.readByte(), equals(0xcc));
      expect(input.isEOS, equals(true));
    });

    test('subset', () async {
      const data = [0xaa, 0xbb, 0xcc, 0xdd, 0xee];
      final input = InputMemoryStream.fromList(data);
      expect(input.length, equals(5));
      expect(input.readByte(), equals(0xaa));

      final i2 = input.subset(length: 3);

      final i3 = i2.subset(position: 1, length: 2);

      expect(i2.readByte(), equals(0xbb));
      expect(i2.readByte(), equals(0xcc));
      expect(i2.readByte(), equals(0xdd));
      expect(i2.isEOS, equals(true));

      expect(i3.readByte(), equals(0xcc));
      expect(i3.readByte(), equals(0xdd));
    });

    test('readString', () async {
      const data = [84, 101, 115, 116, 0];
      final input = InputMemoryStream.fromList(data);
      var s = input.readString();
      expect(s, equals('Test'));
      expect(input.isEOS, equals(true));

      input.reset();

      s = input.readString(size: 4);
      expect(s, equals('Test'));
      expect(input.readByte(), equals(0));
      expect(input.isEOS, equals(true));
    });

    test('readBytes', () async {
      const data = [84, 101, 115, 116, 0];
      final input = InputMemoryStream.fromList(data);
      final b = input.readBytes(3).toUint8List();
      expect(b.length, equals(3));
      expect(b[0], equals(84));
      expect(b[1], equals(101));
      expect(b[2], equals(115));
      expect(input.readByte(), equals(116));
      expect(input.readByte(), equals(0));
      expect(input.isEOS, equals(true));
    });

    test('readUint16', () async {
      const data = [0xaa, 0xbb, 0xcc, 0xdd, 0xee];
      // Little endian (by default)
      final input = InputMemoryStream.fromList(data);
      expect(input.readUint16(), equals(0xbbaa));

      // Big endian
      final i2 =
          InputMemoryStream.fromList(data, byteOrder: ByteOrder.bigEndian);
      expect(i2.readUint16(), equals(0xaabb));
    });

    test('readUint24', () async {
      const data = [0xaa, 0xbb, 0xcc, 0xdd, 0xee];
      // Little endian (by default)
      final input = InputMemoryStream.fromList(data);
      expect(input.readUint24(), equals(0xccbbaa));

      // Big endian
      final i2 =
          InputMemoryStream.fromList(data, byteOrder: ByteOrder.bigEndian);
      expect(i2.readUint24(), equals(0xaabbcc));
    });

    test('readUint32', () async {
      const data = [0xaa, 0xbb, 0xcc, 0xdd, 0xee];
      // Little endian (by default)
      final input = InputMemoryStream.fromList(data);
      expect(input.readUint32(), equals(0xddccbbaa));

      // Big endian
      final i2 =
          InputMemoryStream.fromList(data, byteOrder: ByteOrder.bigEndian);
      expect(i2.readUint32(), equals(0xaabbccdd));
    });

    test('readUint64', () async {
      const data = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0xee, 0xdd];
      // Little endian (by default)
      final input = InputMemoryStream.fromList(data);
      expect(input.readUint64(), equals((0xddeeffee << 32) | 0xddccbbaa));

      // Big endian
      final i2 =
          InputMemoryStream.fromList(data, byteOrder: ByteOrder.bigEndian);
      expect(i2.readUint64(), equals((0xaabbccdd << 32) | 0xeeffeedd));
    }, testOn: 'vm || wasm');
  });
}

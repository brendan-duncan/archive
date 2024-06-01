// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/src/util/ram_file_handle.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

const int _sourceListMinSize = 1;
const int _sourceListMaxSize = 10;
const int _sourceStreamListsMinSize = 1;
const int _sourceStreamListsMaxSize = 10;
const int _targetSubListMinSize = 1;
const int _targetSubListMaxSize = 10;
const int _readIntoSyncMinSize = 1;
const int _readSyncIntoMaxSize = 10;

Stream<List<int>> _buildIntListStream(
  List<int> sourceListsData,
  int sourceListsMaxSize,
) async* {
  for (int i = 0; i < sourceListsData.length;) {
    final int lengthToRead =
        math.min(sourceListsMaxSize, sourceListsData.length - i);
    if (lengthToRead < 1) {
      return;
    }
    yield sourceListsData.getRange(i, i + lengthToRead).toList();
    i += lengthToRead;
  }
}

Future<void> _testRamFileDataBuilder({
  required int sourceListTotalSize,
  required int sourceStreamListsMaxSize,
  required int targetSubListMaxSize,
}) async {
  final List<int> sourceListsData = <int>[];
  for (int i = 0; i < sourceListTotalSize; i++) {
    sourceListsData.add(i);
  }
  final RamFileData data = await RamFileData.fromStream(
    _buildIntListStream(sourceListsData, sourceStreamListsMaxSize),
    sourceListsData.length,
  );
  expect(data.readAsBytes(), Uint8List.fromList(sourceListsData));
  for (int readIntoSyncSize = _readIntoSyncMinSize;
      readIntoSyncSize <= _readSyncIntoMaxSize;
      readIntoSyncSize++) {
    final Uint8List readBuffer = Uint8List(readIntoSyncSize);
    for (int i = 0; i < sourceListsData.length; i++) {
      final int start = i;
      final int end = i + readIntoSyncSize;
      final int readLength = data.readIntoSync(readBuffer, start, end);
      final int actualEnd = math.min(end, sourceListTotalSize);
      expect(
        readLength,
        actualEnd - start,
        reason:
            'readLength had the wrong value when calling readIntoSync($readBuffer, $start, $end)\n'
            'Value of data.content: ${data.content}',
      );
      expect(
        readBuffer.getRange(0, readLength),
        sourceListsData.getRange(start, actualEnd),
        reason: 'readBuffer had the wrong values in it',
      );
    }
  }
}

void main() {
  group('RamFileData initialization -', () {
    test('Various init parameters', () async {
      for (int sourceListTotalSize = _sourceListMinSize;
          sourceListTotalSize <= _sourceListMaxSize;
          sourceListTotalSize++) {
        for (int sourceStreamListsMaxSize = _sourceStreamListsMinSize;
            sourceStreamListsMaxSize <= _sourceStreamListsMaxSize;
            sourceStreamListsMaxSize++) {
          for (int targetSubListMaxSize = _targetSubListMinSize;
              targetSubListMaxSize <= _targetSubListMaxSize;
              targetSubListMaxSize++) {
            await _testRamFileDataBuilder(
              sourceListTotalSize: sourceListTotalSize,
              sourceStreamListsMaxSize: sourceStreamListsMaxSize,
              targetSubListMaxSize: targetSubListMaxSize,
            );
          }
        }
      }
    });

    test(
      'Erratic stream - last item larger than previous items',
      () async {
        Object? triggeredError;
        try {
          await RamFileData.fromStream(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[0, 1],
              <int>[2, 3],
              <int>[4, 5],
              <int>[6, 7, 8, 9],
            ]),
            10,
          );
        } catch (e) {
          triggeredError = e;
        }
        expect(
          triggeredError != null,
          true,
          reason: 'Expected an exception to occur',
        );
      },
    );
    test(
      'Erratic stream - middle item smaller than previous items',
      () async {
        Object? triggeredError;
        try {
          await RamFileData.fromStream(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[0, 1],
              <int>[2],
              <int>[3, 4],
              <int>[5, 6],
              <int>[7, 8],
              <int>[9],
            ]),
            10,
          );
        } catch (e) {
          triggeredError = e;
        }
        expect(
          triggeredError != null,
          true,
          reason: 'Expected an exception to occur',
        );
      },
    );
    test(
      'Erratic stream - middle item larger than previous items',
      () async {
        Object? triggeredError;
        try {
          await RamFileData.fromStream(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[0, 1],
              <int>[2, 3, 4, 5],
              <int>[6, 7],
              <int>[8, 9],
            ]),
            10,
          );
        } catch (e) {
          triggeredError = e;
        }
        expect(
          triggeredError != null,
          true,
          reason: 'Expected an exception to occur',
        );
      },
    );
  });

  test(
    'Writing bytes into a RAM file can be properly read after',
    () async {
      final testData = Uint8List(120);
      for (var i = 0; i < testData.length; ++i) {
        testData[i] = i;
      }
      final List<int> possibleBufferSizes = [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        20,
        30,
        40,
        50
      ];
      final List<int> possibleSubListSizes = [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        20,
        30,
        40,
        50,
        100,
        200
      ];
      for (int subListSize in possibleSubListSizes) {
        for (int bufferSize in possibleBufferSizes) {
          final ramFileData =
              RamFileData.outputBuffer(subListSize: subListSize);
          final ramFileHandle = RamFileHandle.fromRamFileData(ramFileData);
          for (int i = 0; i < testData.length; i += bufferSize) {
            final buffer = Uint8List(bufferSize);
            final absStartIndex = i;
            final absEndIndex = math.min(i + bufferSize, testData.length);
            final int writtenLength = absEndIndex - absStartIndex;
            if (writtenLength <= 0) {
              break;
            }
            buffer.setRange(0, writtenLength,
                testData.getRange(absStartIndex, absEndIndex));
            ramFileHandle.writeFromSync(buffer, 0, writtenLength);
          }
          final outputData1 = Uint8List(ramFileData.length);
          ramFileData.readIntoSync(outputData1, 0, ramFileData.length);
          compareBytes(testData, outputData1);
          final outputData2 = Uint8List(ramFileHandle.length);
          ramFileHandle.readInto(outputData2);
          compareBytes(testData, outputData2);
        }
      }
    },
  );
}

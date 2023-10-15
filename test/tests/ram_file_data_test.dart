// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/src/io/ram_file_handle.dart';
import 'package:test/test.dart';

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
    final int lengthToRead = math.min(sourceListsMaxSize, sourceListsData.length - i);
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
  for (int i = 0; i <= sourceListTotalSize; i++) {
    sourceListsData.add(i);
  }
  final RamFileData data = await RamFileData.fromStream(
    _buildIntListStream(sourceListsData, sourceStreamListsMaxSize),
    sourceListsData.length,
  );
  expect(data.readAsBytes(), Uint8List.fromList(sourceListsData));
  for (int readIntoSyncSize = _readIntoSyncMinSize; readIntoSyncSize <= _readSyncIntoMaxSize; readIntoSyncSize++) {
    final Uint8List readBuffer = Uint8List(readIntoSyncSize);
    for (int i = 0; i < sourceListsData.length; i++) {
      final int start = i;
      final int end = i + readIntoSyncSize;
      final int readLength = data.readIntoSync(readBuffer, start, end);
      final int actualEnd = math.min(end, sourceListTotalSize);
      expect(
        readLength,
        actualEnd - start,
        reason: 'readLength had the wrong value when calling readIntoSync(readBuffer, $start, $end)\n'
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
  group('testRamFileData initialization - ', () {
    for (int sourceListTotalSize = _sourceListMinSize;
        sourceListTotalSize <= _sourceListMaxSize;
        sourceListTotalSize++) {
      for (int sourceStreamListsMaxSize = _sourceStreamListsMinSize;
          sourceStreamListsMaxSize <= _sourceStreamListsMaxSize;
          sourceStreamListsMaxSize++) {
        for (int targetSubListMaxSize = _targetSubListMinSize;
            targetSubListMaxSize <= _targetSubListMaxSize;
            targetSubListMaxSize++) {
          test(
            'Source of $sourceListTotalSize bytes in $sourceStreamListsMaxSize bytes stream chunks, stored in $targetSubListMaxSize bytes chunks',
            () => _testRamFileDataBuilder(
              sourceListTotalSize: sourceListTotalSize,
              sourceStreamListsMaxSize: sourceStreamListsMaxSize,
              targetSubListMaxSize: targetSubListMaxSize,
            ),
          );
        }
      }
    }
  });

  group('Passing an erratic stream produces an exception -', () {
    test(
      'Last item larger than previous items',
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
      'Middle item smaller than previous items',
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
      'Middle item larger than previous items',
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
}

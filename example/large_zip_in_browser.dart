import 'dart:async';
import 'dart:js_interop' as js;
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:web/web.dart' as web;

/// Sample code showing how a large zip file can be extracted and compressed
/// all within the RAM when running in a Web environment.
/// This can be useful if you are limited by the maximum Uint8List size of 2GB
/// in a browser environment for example.
/// Note that unless you have a very specific use case (like handling large zip
/// files in a browser), this method is very costly in RAM and probably
/// sub-optimal compared to other methods documented in the main README.
/// Notes:
/// - The "experimental" boolean flag denotes whether we want to use an
///   experimental method for saving the resulting file to disk
/// - In a web browser environment, a Uint8List cannot be larger than 2GB,
///   which means that only the experimental method will work with for zip
///   files larger than 2GB, and only a few browsers will support it
/// - This assumes all files contained in the zip are no larger than 2GB as
///   well, since those files' data is read as Uint8List instances
void importAndExportLargeZipFile(bool experimental) async {
  // Obtain a file stream to a very large zip file
  final _FileStreamData fileStreamData = await _getFileStream();

  /// Read the stream as an archive and extract all files' data
  final List<_FileData> readFileDataList = await _readZipContentFromStream(
    fileStreamData,
  );

  /// Write all the files into a new zip archive contained in a RamFileData
  final RamFileData writtenZipData = _writeFilesDataAsZipRamData(
    readFileDataList,
  );

  // Save the RamFileData back to the user's computer
  await _saveRamFileDataToDisk(writtenZipData, experimental);
}

Future<_FileStreamData> _getFileStream() async {
  // Using the file picker library:
  // https://pub.dev/packages/file_picker
  // With the following import:
  // import 'package:file_picker/file_picker.dart';
  // The stream can be obtained by the user selecting a file with the following
  // code:
  // final FilePickerResult? result = await FilePicker.platform.pickFiles(
  //   withReadStream: true,
  // );
  // if (result == null) {
  //   throw Exception('No file was picked!');
  // }
  // final PlatformFile singleFile = result.files.single;
  // final Stream<List<int>>? readStream = singleFile.readStream;
  // if (readStream == null) {
  //   throw Exception('Read stream was empty!');
  // }
  // return _FileStreamData(readStream as Stream<Uint8List>, singleFile.size);
  return _FileStreamData(Stream.empty(), 0);
}

Future<List<_FileData>> _readZipContentFromStream(
  _FileStreamData streamData,
) async {
  // Create a RamFileData containing the entire file data in RAM
  final inputRamFileData = await RamFileData.fromStream(
    streamData.stream,
    streamData.length,
  );

  // Create an Archive that will read from the RamFileData
  final archive = ZipDecoder().decodeStream(
    InputFileStream.withFileBuffer(
      FileBuffer(
        RamFileHandle.fromRamFileData(inputRamFileData),
      ),
    ),
  );

  // Going through every archive file and storing it as a _FileData instance
  final extractedFilesData = <_FileData>[];
  for (final file in archive) {
    extractedFilesData.add(_FileData(file.name, file.readBytes()!));
  }

  return extractedFilesData;
}

RamFileData _writeFilesDataAsZipRamData(List<_FileData> fileDataList) {
  // Create a RamFileData that will store the output
  final outputRamFileData = RamFileData.outputBuffer();

  final output = OutputFileStream.toRamFile(
    RamFileHandle.fromRamFileData(outputRamFileData),
  );

  // Create a ZipFileEncoder that will write into the RamFileData
  final zipEncoder = ZipEncoder()..startEncode(output);

  // Write all files into the ZipFileEncoder
  for (final _FileData fileData in fileDataList) {
    zipEncoder.add(ArchiveFile.bytes(
      fileData.fileName,
      fileData.fileBytes,
    ));
  }

  // Close the ZipFileEncoder
  zipEncoder.endEncode();

  return outputRamFileData;
}

/// Creates an <a> tag on which we simulate a click to trigger the download of
/// the data. This method only works if the size of the data to download is
/// lower than 2GB.
Future<void> _saveRamFileDataToDiskRegular(RamFileData ramFileData) async {
  final fileBytes = Uint8List(ramFileData.length);
  ramFileData.readIntoSync(fileBytes, 0, fileBytes.length);
  final blob = web.Blob(
      [fileBytes.toJS].toJS, web.BlobPropertyBag(type: 'application/zip'));
  final dataUrl = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement();
  a.href = dataUrl;
  a
    ..setAttribute('download', 'exported_file.zip')
    ..click();
}

/// !!! EXPERIMENTAL !!! It is discouraged to use this experimental method
/// in a production environment - use this method only if you're certain
/// of what you're doing or willing to accept the tradeoffs.
/// More explanations about what "experimental" means here:
/// https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Experimental_deprecated_obsolete#experimental
Future<void> _saveRamFileDataToDiskExperimental(
  RamFileData ramFileData,
) async {
  await _ExperimentalFileSaver.saveRamFileDataAsFile(
    'exported_file.zip',
    ramFileData,
  );
}

Future<void> _saveRamFileDataToDisk(
  RamFileData ramFileData,
  bool experimental,
) {
  if (experimental) {
    return _saveRamFileDataToDiskExperimental(ramFileData);
  } else {
    return _saveRamFileDataToDiskRegular(ramFileData);
  }
}

class _FileStreamData {
  final Stream<Uint8List> stream;
  final int length;

  _FileStreamData(this.stream, this.length);
}

class _FileData {
  final String fileName;
  final Uint8List fileBytes;

  _FileData(this.fileName, this.fileBytes);
}

/// !!! EXPERIMENTAL !!! Not recommended for production, use at your own risks!
/// More explanations about what "experimental" means here:
/// https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Experimental_deprecated_obsolete#experimental
class _ExperimentalFileSaver {
  static Future<T> _callJsMethod<T>(
    js.JSObject calledObj,
    String methodName, [
    List<dynamic>? params,
  ]) async {
    final completer = Completer<T>();

    final promiseObj = calledObj.callMethodVarArgs(
        methodName.toJS,
        (params?.map((e) => e.toJS) ?? []).toList(growable: false)
            as List<js.JSAny?>) as js.JSObject;

    final thenObj = promiseObj.callMethodVarArgs(
      'then'.toJS,
      <js.JSAny>[
        (
          T promiseResult,
        ) {
          completer.complete(promiseResult);
        }.toJSBox
      ],
    ) as js.JSObject;

    thenObj.callMethodVarArgs('catch'.toJS, <js.JSAny>[
      (
        js.JSObject errorResult,
      ) {
        completer.completeError(
          '_callJsMethod encountered an error calling the method "$methodName": $errorResult',
        );
      }.toJSBox
    ]);
    return completer.future;
  }

  static Future<void> saveRamFileDataAsFile(
    String fileName,
    RamFileData ramFileData,
  ) async {
    // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle
    final js.JSObject fileSystemFileHandle;
    fileSystemFileHandle = await _callJsMethod(
      web.window,
      // https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker
      'showSaveFilePicker',
      <js.JSAny>[
        <String, Object>{
          'suggestedName': fileName,
          'writable': true,
        }.toJSBox,
      ],
    );
    // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream
    final js.JSObject fileSystemWritableFileStream;
    fileSystemWritableFileStream = await _callJsMethod<js.JSObject>(
      fileSystemFileHandle,
      'createWritable',
    );
    const defaultBufferSize = 1024 * 1024;
    Uint8List? buffer;
    for (int i = 0; i < ramFileData.length; i += defaultBufferSize) {
      final bufferSize = math.min(
        defaultBufferSize,
        ramFileData.length - i,
      );
      if (buffer == null || bufferSize != buffer.length) {
        buffer = Uint8List(bufferSize);
      }
      ramFileData.readIntoSync(buffer, i, i + bufferSize);
      // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream/write
      await _callJsMethod<void>(
        fileSystemWritableFileStream,
        'write',
        <js.JSAny>[
          web.Blob([buffer.toJS].toJS)
        ],
      );
    }
    await _callJsMethod<void>(
      fileSystemWritableFileStream,
      'close',
    );
  }
}

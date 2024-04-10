import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

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

  // Read the stream as an archive and extract all files' data
  final List<_FileData> readFileDataList = await _readZipContentFromStream(
    fileStreamData,
  );

  // Write all the files into a new zip archive contained in a RamFileData
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
  final RamFileData inputRamFileData = await RamFileData.fromStream(
    streamData.stream,
    streamData.length,
  );

  // Create an Archive that will read from the RamFileData
  final Archive archive = ZipDecoder().decodeBuffer(
    InputFileStream.withFileBuffer(
      FileBuffer(
        RamFileHandle.fromRamFileData(inputRamFileData),
      ),
    ),
  );

  // Going through every archive file and storing it as a _FileData instance
  final List<_FileData> extractedFilesData = [];
  for (final ArchiveFile file in archive.files) {
    extractedFilesData.add(_FileData(file.name, file.content as Uint8List));
  }

  return extractedFilesData;
}

RamFileData _writeFilesDataAsZipRamData(List<_FileData> fileDataList) {
  // Create a RamFileData that will store the output
  final RamFileData outputRamFileData = RamFileData.outputBuffer();

  // Create a ZipFileEncoder that will write into the RamFileData
  final ZipFileEncoder zipEncoder = ZipFileEncoder()
    ..createWithBuffer(
      OutputFileStream.toRamFile(
        RamFileHandle.fromRamFileData(outputRamFileData),
      ),
    );

  // Write all files into the ZipFileEncoder
  for (final _FileData fileData in fileDataList) {
    zipEncoder.addArchiveFile(ArchiveFile(
      fileData.fileName,
      fileData.fileBytes.length,
      fileData.fileBytes,
    ));
  }

  // Close the ZipFileEncoder
  zipEncoder.closeSync();

  return outputRamFileData;
}

/// Creates an <a> tag on which we simulate a click to trigger the download of
/// the data. This method only works if the size of the data to download is
/// lower than 2GB.
Future<void> _saveRamFileDataToDiskRegular(RamFileData ramFileData) async {
  final Uint8List fileBytes = Uint8List(ramFileData.length);
  ramFileData.readIntoSync(fileBytes, 0, fileBytes.length);
  final String dataUrl = html.Url.createObjectUrlFromBlob(html.Blob(
    <dynamic>[fileBytes],
    'application/zip',
  ));
  html.AnchorElement(href: dataUrl)
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
    js.JsObject calledObj,
    String methodName, [
    List<dynamic>? params,
  ]) async {
    final Completer<T> completer = Completer<T>();
    final js.JsObject promiseObj = calledObj.callMethod(
      methodName,
      <dynamic>[
        if (params != null) ...params,
      ],
    ) as js.JsObject;
    final js.JsObject thenObj = promiseObj.callMethod(
      'then',
      <dynamic>[
        (
          T promiseResult,
        ) {
          completer.complete(promiseResult);
        }
      ],
    ) as js.JsObject;
    thenObj.callMethod('catch', <dynamic>[
      (
        js.JsObject errorResult,
      ) {
        completer.completeError(
          '_callJsMethod encountered an error calling the method "$methodName": $errorResult',
        );
      }
    ]);
    return completer.future;
  }

  static Future<void> saveRamFileDataAsFile(
    String fileName,
    RamFileData ramFileData,
  ) async {
    // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle
    final js.JsObject fileSystemFileHandle;
    fileSystemFileHandle = await _callJsMethod(
      js.context,
      // https://developer.mozilla.org/en-US/docs/Web/API/Window/showSaveFilePicker
      'showSaveFilePicker',
      <dynamic>[
        js.JsObject.jsify(<String, Object>{
          'suggestedName': fileName,
          'writable': true,
        }),
      ],
    );
    // https://developer.mozilla.org/en-US/docs/Web/API/FileSystemWritableFileStream
    final js.JsObject fileSystemWritableFileStream;
    fileSystemWritableFileStream = await _callJsMethod<js.JsObject>(
      fileSystemFileHandle,
      'createWritable',
    );
    const int defaultBufferSize = 1024 * 1024;
    Uint8List? buffer;
    for (int i = 0; i < ramFileData.length; i += defaultBufferSize) {
      final int bufferSize = math.min(
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
        <dynamic>[
          html.Blob(<dynamic>[buffer])
        ],
      );
    }
    await _callJsMethod<void>(
      fileSystemWritableFileStream,
      'close',
    );
  }
}

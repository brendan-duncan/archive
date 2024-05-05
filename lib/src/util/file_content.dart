import 'dart:typed_data';

import 'input_memory_stream.dart';
import 'input_stream.dart';
import 'output_stream.dart';

abstract class FileContent {
  InputStream getStream();

  void write(OutputStream output);

  Future<void> close();

  void closeSync();

  Uint8List readBytes() {
    final stream = getStream();
    return stream.toUint8List();
  }

  void decompress(OutputStream output) {
    output.writeStream(getStream());
  }

  bool get isCompressed => false;
}

class FileContentMemory extends FileContent {
  final Uint8List bytes;

  FileContentMemory(List<int> data)
      : bytes = data is Uint8List ? data : Uint8List.fromList(data);

  @override
  InputStream getStream() => InputMemoryStream(bytes);

  @override
  void write(OutputStream output) => output.writeBytes(bytes);

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}
}

class FileContentStream extends FileContent {
  final InputStream stream;

  FileContentStream(this.stream);

  @override
  InputStream getStream() => stream;

  @override
  void write(OutputStream output) => output.writeStream(stream);

  @override
  Future<void> close() async => stream.close();

  @override
  void closeSync() => stream.closeSync();
}

import 'dart:typed_data';

import 'input_stream.dart';
import 'input_stream_memory.dart';
import 'output_stream.dart';

abstract class FileContent {
  InputStream getStream();

  void write(OutputStream output);

  void close();

  Uint8List readBytes() {
    final stream = getStream();
    return stream.toUint8List();
  }

  void decompress(OutputStream output) {}
}

class FileContentMemory extends FileContent {
  final Uint8List bytes;

  FileContentMemory(this.bytes);

  @override
  InputStream getStream() => InputStreamMemory(bytes);

  @override
  void write(OutputStream output) => output.writeBytes(bytes);

  @override
  void close() {}
}

class FileContentStream extends FileContent {
  final InputStream stream;

  FileContentStream(this.stream);

  @override
  InputStream getStream() => stream;

  @override
  void write(OutputStream output) => output.writeStream(stream);

  @override
  void close() => stream.close();
}

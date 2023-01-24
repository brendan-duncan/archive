import 'dart:typed_data';

import 'input_stream.dart';
import 'input_stream_memory.dart';
import 'output_stream.dart';

abstract class FileContent {
  Future<InputStream> getStream();

  Future<void> write(OutputStream output);

  Future<void> close();

  Future<Uint8List> readBytes() async {
    final stream = await getStream();
    return stream.toUint8List();
  }

  Future<void> decompress(OutputStream output) async {}
}

class FileContentMemory extends FileContent {
  final Uint8List bytes;

  FileContentMemory(this.bytes);

  @override
  Future<InputStream> getStream() async => InputStreamMemory(bytes);

  @override
  Future<void> write(OutputStream output) async => output.writeBytes(bytes);

  @override
  Future<void> close() async {}
}

class FileContentStream extends FileContent {
  final InputStream stream;

  FileContentStream(this.stream);

  @override
  Future<InputStream> getStream() async => stream;

  @override
  Future<void> write(OutputStream output) async => output.writeStream(stream);

  @override
  Future<void> close() async => stream.close();
}

import 'dart:io';
import 'dart:typed_data';

Future<void> writeTarEntryFile(String path, Stream<Object> parts) async {
  final file = await File(path).open(mode: FileMode.write);
  try {
    var at = 0;
    await for (final part in parts) {
      if (part is int) {
        at += part;
        await file.setPosition(at);
      } else {
        final bytes = part as Uint8List;
        await file.writeFrom(bytes);
        at += bytes.length;
      }
    }
    await file.truncate(at);
  } finally {
    await file.close();
  }
}

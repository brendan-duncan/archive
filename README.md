#archive - Dart library to encode and decode various archive and compression formats.

The archive library currently supports:

*Decoders*:
Zip (Package file)
Tar (Package file)
ZLib (Compression)
GZip (Compression)

*Encoders*:
None yet.  Adding Encoders is on my TODO.

Sample usage extract the contents of a Zip file:

    import 'dart:io' as Io;
    import 'package:archive/archive.dart';
    main() {
      Io.File file = new Io.File('test.zip');
      file.openSync();
      var bytes = file.readAsBytesSync();
      if (bytes == null) {
        return;
      }
    
      var zip = new ZipDecoder(bytes);
      for (int i = 0; i < zip.numberOfFiles(); ++i) {
        String filename = zip.fileName(i);
        List<int> data = zip.fileData(i);
        Io.File fp = new Io.File('out/' + filename);
        fp.createSync(recursive: true);
        fp.writeAsBytesSync(data);
      }
    }

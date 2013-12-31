#archive - Dart library to encode and decode various archive and compression formats.

The library has no reliance on *dart:io*, so it can be used for both server
and web applications.

The archive library currently supports:

*Decoders*:
Zip (Archive)
Tar (Archive)
ZLib (Compression) [Inflate decompression]
GZip (Compression) [Inflate decompression]

*Encoders*:
None yet.  Adding Encoders is on my TODO.

Sample: Extract the contents of a Zip file.

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

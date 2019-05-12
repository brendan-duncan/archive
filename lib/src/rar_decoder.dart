import 'util/input_stream.dart';
import 'archive.dart';
//import 'archive_file.dart';
import 'rar/rar_archive.dart';

/// Decode a rar formatted buffer into an [Archive] object.
class RarDecoder {
  Archive decodeBytes(List<int> data) {
    return decodeBuffer(InputStream(data));
  }

  Archive decodeBuffer(dynamic input) {
    var archive = Archive();

    /*var rarArchive =*/ RarArchive(input);

    return archive;
  }
}
// ignore_for_file: avoid_print
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart';

void main() async {
  // An img on the html page is used to establish the path to the images
  // directory.  It's removed after we get the path since we'll be populating
  // the page with our own decoded images.
  final img = document.querySelectorAll('img').item(0) as HTMLImageElement;
  final path = img.src.substring(0, img.src.lastIndexOf('/'));
  img.remove();

  // Use an http request to get the image file from disk.
  var url = Uri.parse('$path/readme.zip');
  var response = await http.get(url);
  if (response.statusCode == 200) {
    final archive = ZipDecoder().decodeBytes(response.bodyBytes);
    print('NUMBER OF FILES ${archive.length}');
    print(archive[0].name);
    print(archive[0].size);
    final decoded = archive[0].readBytes();
    print(String.fromCharCodes(decoded!));
  }
}

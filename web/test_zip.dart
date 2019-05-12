import 'dart:html';
import 'dart:typed_data';
import 'package:archive/archive.dart';

void main() {
  // An img on the html page is used to establish the path to the images
  // directory.  It's removed after we get the path since we'll be populating
  // the page with our own decoded images.
  ImageElement img = querySelectorAll('img')[0];
  String path = img.src.substring(0, img.src.lastIndexOf('/'));
  img.remove();

  // Use an http request to get the image file from disk.
  var req = HttpRequest();
  req.open('GET', path + '/readme.zip');
  req.responseType = 'arraybuffer';
  req.onLoadEnd.listen((e) {
    if (req.status == 200) {
      // Convert the text to binary byte list.
      Uint8List bytes = Uint8List.view(req.response);
      var archive = ZipDecoder().decodeBytes(bytes, verify: true);
      print("NUMBER OF FILES ${archive.numberOfFiles()}");
    }
 });
 req.send('');
}

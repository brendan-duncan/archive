import 'dart:html' as Html;
import 'dart:async' as Async;
import 'dart:typed_data';
import 'package:archive/archive.dart';

void main() {
  // An img on the html page is used to establish the path to the images
  // directory.  It's removed after we get the path since we'll be populating
  // the page with our own decoded images.
  Html.ImageElement img = Html.querySelectorAll('img')[0];
  String path = img.src.substring(0, img.src.lastIndexOf('/'));
  img.remove();

  // Use an http request to get the image file from disk.
  var req = new Html.HttpRequest();
  req.open('GET', path + '/readme.zip');
  req.responseType = 'arraybuffer';
  req.onLoadEnd.listen((e) {
    if (req.status == 200) {
      // Convert the text to binary byte list.
      Uint8List bytes = new Uint8List.view(req.response);
      var archive = new ZipDecoder().decodeBytes(bytes, verify: true);
      print("NUMBER OF FILES ${archive.numberOfFiles()}");
    }
 });
 req.send('');
}

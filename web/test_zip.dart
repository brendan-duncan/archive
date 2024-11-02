// ignore_for_file: avoid_print

import 'dart:html';
import 'dart:typed_data';

import 'package:archive/archive.dart';

void main() {
  // An img on the html page is used to establish the path to the images
  // directory.  It's removed after we get the path since we'll be populating
  // the page with our own decoded images.
  final img = querySelectorAll('img')[0] as ImageElement;
  final path = img.src!.substring(0, img.src!.lastIndexOf('/'));
  img.remove();

  // Use an http request to get the image file from disk.
  var req = HttpRequest();
  req.open('GET', '$path/readme.zip');
  req.responseType = 'arraybuffer';
  req.onLoadEnd.listen((e) {
    if (req.status == 200) {
      // Convert the text to binary byte list.
      final bytes = Uint8List.view(req.response as ByteBuffer);
      print(bytes);
      final archive = ZipDecoder().decodeBytes(bytes);
      print('NUMBER OF FILES ${archive.length}');
      print(archive[0].name);
      print(archive[0].size);
      print(archive[0].compression);
      final decoded = archive[0].readBytes();
      print(decoded);
    }
  });
  req.send('');
}

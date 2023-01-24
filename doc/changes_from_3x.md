# Changes From Archive 3.x to 4.x

The Dart Archive Library was written many years ago and the Dart language
has evolved a lot since then. Flutter didn't exist. Archive 4.0 is a fresh
start rewrite of the library to better accommodate the current language features
and style, and to prioritize dart:io and Flutter over dart:html, though web builds
will not lose anything. It is considered a major breaking change version, but I hope
it will not be too disruptive.

## InputStream

InputStream used to be derived from InputStreamBase, and included a sibling class
InputFileStream. These classes have been rewritten to:
* InputStream
  * InputStreamMemory
  * InputStreamFile


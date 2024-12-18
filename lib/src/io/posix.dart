export 'posix_stub.dart'
    if (dart.library.io) 'posix_io.dart'
    if (dart.library.js) 'posix_html.dart';

// XXH64 needs 64 bit multiplication, so it is written twice: directly where an
// int is a real 64 bit integer, and in 32 bit halves where it is a JavaScript
// number. The 64 bit version could not even be compiled for JavaScript, whose
// numbers cannot represent its constants.
//
// dart:isolate is available on exactly the VM and wasm, the backends with 64
// bit ints, which is what selects the direct version. The split version is the
// default because it is correct everywhere.
export 'xxhash64_32.dart' if (dart.library.isolate) 'xxhash64_64.dart';

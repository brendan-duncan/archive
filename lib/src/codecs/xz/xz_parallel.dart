// Decoding across isolates, where the platform has them.
//
// The guard has to be dart.library.io. It is false on dart2js and on
// dart2wasm alike, which is exactly the set of targets that cannot spawn an
// isolate. dart.library.isolate looks like the obvious choice and is wrong:
// it is true on dart2wasm, where Isolate.spawn does not work.
export '_xz_parallel_stub.dart' if (dart.library.io) '_xz_parallel_io.dart';

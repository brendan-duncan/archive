/// Whether this is dart2wasm. There, a Uint8List may be backed by a
/// JavaScript array, every access to which is a call out of wasm, so the
/// encoder copies its input into one of its own before searching it.
const bool zstdIsWasm = bool.fromEnvironment('dart.tool.dart2wasm');

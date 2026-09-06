// The range decoder is written twice. The native implementation relies on 64
// bit integer arithmetic to decode bits without data dependent branches, which
// cannot be expressed where an int is a JavaScript number, so JavaScript
// targets get a branching implementation instead.
//
// The condition has to separate the backends where an int is a real 64 bit
// integer, the VM and wasm, from the ones where it is a JavaScript number.
// dart:isolate is available on exactly those two and not on dart2js, which is
// what makes it the right question to ask here, even though nothing below
// spawns an isolate. dart:io looks like the obvious choice and is wrong: it is
// unavailable on wasm, which used to leave wasm on the branching path.
//
// Getting this wrong in one direction costs speed and in the other costs
// correctness. Decoding 1.9 MB, native against branching: 11.9 ms against
// 12.7 ms on the VM, 17.0 ms against 19.0 ms on wasm, and on dart2js the
// native implementation does not merely run slowly, it throws. The branching
// implementation is therefore the default, because it is correct anywhere.
export 'range_decoder_table.dart';
export 'range_decoder_web.dart'
    if (dart.library.isolate) 'range_decoder_native.dart';

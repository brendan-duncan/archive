// The backward bit reader is written twice. Where an int is a real 64 bit
// integer, a container that wide means a refill every seven bytes or so and
// lets a whole sequence's worth of fields come out of one load. Where an int
// is a JavaScript number the bitwise operators truncate to 32 bits, so a
// container wider than that silently loses bits, and that reader holds 30,
// refills about twice as often and splits the rare reads wider than 22 bits.
//
// As with the range decoder, dart:isolate is what separates the two: it is
// available on exactly the VM and wasm, the backends with 64 bit ints. The 32
// bit reader is the default because it is correct everywhere.
export 'zstd_bit_reader_32.dart'
    if (dart.library.isolate) 'zstd_bit_reader_64.dart';

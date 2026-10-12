/// How much of the input to hand the native codec at a time.
///
/// Measured on a 1 GB file to file gzip: 64 KB chunks encode 23% faster and
/// decode 12% faster than the 1 KB and 8 KB chunks used before, and larger
/// chunks gain nothing more.
const int zlibChunkSize = 64 * 1024;

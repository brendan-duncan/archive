/// How much of the input to hand the native codec at a time.
///
/// Measured on a 1 GB file to file gzip: 64 KB chunks encode 23% faster and
/// decode 12% faster than the 1 KB and 8 KB chunks used before, and larger
/// chunks gain nothing more.
///
/// 16 KB is used instead, since it fits the 32 KB L1 data cache of
/// Cortex-A53 and A55 cores
const int zlibChunkSize = 16 * 1024;

/// How much memory the isolates may hold at once by default, in bytes
const zstdDefaultMemoryBudget = 1024 * 1024 * 1024;

/// `zstd -T`.
/// {@macro archive.multithreaded_header}
/// {@macro archive.multithreaded_examples}
class ZstdMultithreadOptions<T> {
  /// {@macro archive.multithreaded_memory_on_done}
  final void Function(T result)? onDone;

  /// {@macro archive.multithreaded_memory_on_error}
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// {@macro archive.multithreaded_workers}
  final int? workers;

  /// {@macro archive.multithreaded_memory_budget}
  final int? memoryBudget;

  /// `ZSTD_c_jobSize`, zero for `1 << max(20, windowLog + 2)`
  final int jobSize;

  /// `ZSTD_c_overlapLog`, zero for the level's own, 9 for the whole window
  final int overlapLog;

  /// Called with the count of input bytes compressed so far, finished jobs and
  /// the part of running ones, as `Read:` of `zstd --progress`. Jobs are taken
  /// ahead of that point, so the count of bytes sent out reaches the end
  /// long before the work does.
  /// An exception it throws goes to the zone and the encode continues
  final void Function(int consumed)? onProgress;

  const ZstdMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.jobSize = 0,
    this.overlapLog = 0,
    this.onProgress,
  });

  /// {@macro archive.multithreaded_header}
  /// {@macro archive.yield_codecs_multithreaded_example}
  const ZstdMultithreadOptions.converter({
    this.workers,
    this.memoryBudget,
    this.jobSize = 0,
    this.overlapLog = 0,
    this.onProgress,
  })  : onDone = null,
        onError = null;
}

/// The four fields that describe the work, checked the same way wherever the
/// options arrive: a value no path can honour is a mistake at the call, not a
/// failure of the encode
void checkZstdMultithreadOptions(ZstdMultithreadOptions<Object?> options) {
  final workers = options.workers;
  if (workers != null && workers < 1) {
    throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
  }
  final budget = options.memoryBudget;
  if (budget != null && budget < 1) {
    throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
  }
  if (options.overlapLog < 0 || options.overlapLog > 9) {
    throw ArgumentError.value(
        options.overlapLog, 'overlapLog', 'Must be 0 to 9');
  }
  if (options.jobSize < 0) {
    throw ArgumentError.value(
        options.jobSize, 'jobSize', 'Must not be negative');
  }
}

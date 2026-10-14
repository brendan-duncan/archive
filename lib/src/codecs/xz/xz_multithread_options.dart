import '_xz_no_result.dart';

/// How much memory the isolates may hold at once by default, in bytes
const xzDefaultMemoryBudget = 1024 * 1024 * 1024;

/// {@macro archive.multithreaded_header}
/// {@macro archive.multithreaded_examples}
class XZMultithreadOptions<T> {
  /// {@macro archive.multithreaded_header}
  /// {@macro archive.yield_codecs_multithreaded_example}
  const XZMultithreadOptions.converter({
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  })  : onDone = xzNoResult,
        onError = null;

  const XZMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  });

  /// {@macro archive.multithreaded_memory_on_done}
  final void Function(T result) onDone;

  /// {@macro archive.multithreaded_memory_on_error}
  ///
  /// A corrupted or truncated archive reaches this with `throwOnError`, and
  /// failed block check only with `throwOnError` and `verify`
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// {@macro archive.multithreaded_workers}
  final int? workers;

  /// {@macro archive.multithreaded_memory_budget}
  final int? memoryBudget;

  /// Only `decodeStream` over an `InputFileStream` uses this. A stream cannot
  /// cross an isolate boundary, so a worker cannot reach the `bufferSize` you
  /// chose.
  ///
  /// Workers read different parts of the file at once. Where a seek costs
  /// something, this decides how often we pay for it. A 189 MB block takes 1312
  /// reads through 256 KB, 368 through 1 MB and 52 through the 8 MB default.
  ///
  /// It works against [memoryBudget] like everything else, so raising it
  /// lowers the worker count
  final int fileReadBufferSize;
}

/// Default ceiling on the memory the isolates may hold at once, in bytes.
///
/// Only the blocks that are being decoded are counted against it: the archive
/// and the decoded output live in the calling isolate and are not affected by
/// how many workers are running.
const xzDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Turns an [XZDecoder] call into a decode that runs on isolates.
///
/// Passing one of these switches that single call into multithreaded mode. The
/// method returns immediately and the result arrives through [onDone] instead
/// of the return value, because an isolate cannot be waited on synchronously.
///
/// ```dart
/// final completer = Completer<Uint8List>();
/// XZDecoder().decodeBytes(compressed,
///     multithread: XZMultithreadOptions(
///       onDone: completer.complete,
///       onError: (error, _) => completer.completeError(error),
///     ));
/// final data = await completer.future;
/// ```
///
/// The type argument follows the method being called: [Uint8List] for
/// [XZDecoder.decodeBytes] and [bool] for [XZDecoder.decodeStream]. It is
/// inferred from the method, so writing `XZMultithreadOptions(onDone: (result)
/// { ... })` is enough.
class XZMultithreadOptions<T> {
  /// Called exactly once with the result of the decode.
  ///
  /// This is the only place the result appears. It is called even when the
  /// archive turns out not to be worth splitting up, and on platforms without
  /// isolates, so a caller never has to special case either.
  final void Function(T result) onDone;

  /// Called instead of [onDone] when the decode fails.
  ///
  /// Two different things arrive here. Failures that would otherwise have been
  /// thrown, such as an isolate that could not be started, always do. A merely
  /// truncated or corrupt archive does only when `throwOnError` was set on the
  /// call: without it that outcome is not treated as an error at all and
  /// reaches [onDone] as the partial output, or as false, the same way the
  /// synchronous methods report it through their return value.
  ///
  /// Leaving this null is allowed only without `throwOnError`, and then routes
  /// a genuine failure to [onDone] instead, reported the same way an invalid
  /// archive is. Nothing is ever thrown into the void: an error that had
  /// nowhere to go would otherwise go unnoticed entirely. Setting
  /// `throwOnError` without this is refused outright, because the exception it
  /// asks for would have nowhere to be delivered.
  ///
  /// This is not where a bad setting lands. [workers], [memoryBudget] and
  /// [fileReadBufferSize] are checked before any work starts, and a value that
  /// cannot be honoured throws [ArgumentError] at the call, whatever
  /// `throwOnError` says.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Maximum number of isolates to decode on.
  ///
  /// Defaults to one less than [Platform.numberOfProcessors], leaving a core
  /// for the calling isolate, and never exceeds the number of blocks in the
  /// archive. A value above [Platform.numberOfProcessors] is clamped down to
  /// it: more workers than cores costs memory and context switches without
  /// decoding any faster. Must be at least 1.
  ///
  /// [memoryBudget] can still lower the number this produces.
  final int? workers;

  /// Ceiling on the memory the isolates may hold at once, in bytes.
  ///
  /// Defaults to [xzDefaultMemoryBudget]. It is what decides how many blocks
  /// can be in flight, and it applies on top of [workers], including when
  /// [workers] was given explicitly, so that it can act as a safety valve. At
  /// least one worker always runs, however small the budget.
  ///
  /// What each worker is charged for depends on the call:
  ///
  /// - an LZMA2 dictionary, sized by the block header, and a small staging
  ///   buffer, always;
  /// - the compressed block, when the archive was handed over as bytes. Given
  ///   a file to read instead, a worker streams its block through a small
  ///   window and is charged for that window;
  /// - one decoded block, when the output can only be appended to, because
  ///   blocks that finish ahead of their turn have to be held back.
  ///
  /// So the same budget buys markedly more workers for
  /// `decodeStream(InputFileStream, ...)` than for [decodeBytes], which is
  /// another reason to prefer it.
  ///
  /// There is no portable way to ask the system how much memory is available —
  /// Dart exposes [Platform.numberOfProcessors] and nothing equivalent for
  /// memory — so a phone and a workstation need different values here and the
  /// package cannot tell them apart on its own.
  final int? memoryBudget;

  /// Buffer a worker reads its block through, in bytes.
  ///
  /// This only applies to `decodeStream` reading from an `InputFileStream`,
  /// which is the one case where the workers open the file themselves: a
  /// stream cannot cross an isolate boundary, so the buffer the caller chose
  /// cannot be reached from inside a worker. Everywhere else the caller
  /// already owns that decision, by passing `bufferSize` to `InputFileStream`.
  ///
  /// Workers read different parts of the file at the same time, so the drive
  /// sees their requests interleaved rather than as one sweep. Where a seek
  /// costs something, that is the expensive part, and this is what decides how
  /// often it is paid: a 189 MB block takes 1312 reads through a 256 KB
  /// buffer, 368 through 1 MB, and 52 through the 8 MB default.
  ///
  /// On a fast disk none of it shows, because the page cache answers most
  /// reads; on a spinning or networked one it dominates, and fewer workers
  /// with a larger buffer will beat more workers with a small one. It is
  /// charged against [memoryBudget] like everything else, so raising it lowers
  /// the number of workers that fit. Values below the minimum a file buffer
  /// can take are raised to it rather than rejected.
  final int fileReadBufferSize;

  const XZMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  });
}

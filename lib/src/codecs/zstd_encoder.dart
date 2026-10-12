import 'dart:async';
import 'dart:typed_data';

import '../util/decode_guard.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import '../util/report_progress.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_frame_encoder.dart';
import 'zstd/zstd_level_params.dart';
import 'zstd/zstd_mt_frame_encoder.dart';
import 'zstd/zstd_mt_parallel.dart';
import 'zstd/zstd_multithread_options.dart';

export 'zstd/zstd_level_params.dart'
    show zstdDefaultLevel, zstdMaxLevel, zstdMinLevel;
export 'zstd/zstd_multithread_options.dart';

/// Compress data with the zstd format encoder
class ZstdEncoder {
  final int level;

  /// Placed before the content so matches can reach into it, and named in the
  /// frame header, so only the same dictionary reads the frame back
  final ZstdDictionary? dictionary;

  /// [dictionary] may be a dictionary in the zstd format, as `zstd --train`
  /// writes, or any other bytes, which are then used as raw content
  ZstdEncoder({int level = zstdDefaultLevel, List<int>? dictionary})
      : this.withDictionary(
            dictionary == null ? null : ZstdDictionary(dictionary),
            level: level);

  /// Takes a [ZstdDictionary] parsed once, so encoders can share it
  const ZstdEncoder.withDictionary(this.dictionary,
      {this.level = zstdDefaultLevel});

  /// [checksum] is whether the frame has an XXH64 of its content.
  ///
  /// With [multithread] the frame is the one `zstd -T` writes, not the one the
  /// single threaded encoder writes, and it arrives through `onDone` rather
  /// than as the return value. The return value is then empty.
  ///
  /// A setting that cannot be honoured throws [ArgumentError] here, before
  /// the call returns; only a failure of the work itself reaches
  /// `onError`, and without one it reaches `onDone` as empty output
  Uint8List encodeBytes(List<int> data,
      {int? level,
      bool checksum = false,
      ZstdMultithreadOptions<Uint8List>? multithread}) {
    if (multithread == null) {
      final output = OutputMemoryStream();
      encodeStream(InputMemoryStream(data), output,
          level: level, checksum: checksum);
      return output.getBytes();
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _checkMultithread(multithread);
    // The work runs after this call returns, so we check the level here: an
    // ArgumentError thrown inside the job reaches onDone as an empty result
    final chosen = zstdEffectiveLevel(level ?? this.level);
    _reportAsync(
        multithread,
        () => _multithreadBytes(bytes, chosen, checksum, multithread),
        Uint8List(0));
    return Uint8List(0);
  }

  /// `ZSTDMT_JOBSIZE_MIN`: the reference turns its workers off below this, so
  /// the frame is the single threaded one
  Future<Uint8List> _multithreadBytes(Uint8List bytes, int level, bool checksum,
      ZstdMultithreadOptions<Object?> options) {
    if (bytes.length <= zstdMtJobSizeMin) {
      final encoded = encodeBytes(bytes, level: level, checksum: checksum);
      reportProgress(options.onProgress, bytes.length);
      return Future.value(encoded);
    }
    return zstdMtCompress(bytes, level,
        checksum: checksum,
        jobSize: options.jobSize,
        overlapLog: options.overlapLog,
        workers: options.workers ?? 0,
        memoryBudget: options.memoryBudget ?? zstdDefaultMemoryBudget,
        dictionary: _dictionary,
        onProgress: options.onProgress);
  }

  static void _reportAsync<T>(ZstdMultithreadOptions<T> options,
      Future<T> Function() work, T onFailure) {
    final onDone = options.onDone!;
    unawaited(work().then(onDone, onError: (Object error, StackTrace stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(archiveError(error, 'zstd: '), stack);
      } else {
        onDone(onFailure);
      }
    }));
  }

  void _checkMultithread<T>(ZstdMultithreadOptions<T> options) {
    if (options.onDone == null) {
      throw ArgumentError.value(
          null,
          'onDone',
          'Must be given here, since this call has nowhere else to put the '
              'result; only the converter carries its own end');
    }
    checkZstdMultithreadOptions(options);
  }

  ZstdDictionary? get _dictionary {
    final dict = dictionary;
    return dict != null && dict.usableForEncode ? dict : null;
  }

  List<int> encode(List<int> data, {int? level}) =>
      encodeBytes(data, level: level);

  /// Compress [input] into [output] as one frame, holding only its window.
  ///
  /// With [multithread] over a file, each worker reads its own job from disk,
  /// so the input never sits in this isolate; over any other stream the bytes
  /// are read in first. `onDone` is called with true when the frame is written
  void encodeStream(InputStream input, OutputStream output,
      {int? level,
      bool checksum = false,
      ZstdMultithreadOptions<bool>? multithread}) {
    if (multithread != null) {
      _checkMultithread(multithread);
      final chosen = zstdEffectiveLevel(level ?? this.level);
      // Reading the input is part of the work and reports through onError. The
      // body up to the first await still runs here, so the input is consumed
      // before the call returns, as it was when the reads stood outside
      _reportAsync(multithread, () async {
        final region = zstdMtFileRegion(input);
        // A dictionary belongs to the first job, and a worker reading its own
        // slice of a file has no way to be given one, so that path reads the
        // bytes in instead
        if (input.length <= zstdMtJobSizeMin ||
            region == null ||
            _dictionary != null) {
          final bytes = input.toUint8List();
          input.skip(input.length);
          output.writeBytes(
              await _multithreadBytes(bytes, chosen, checksum, multithread));
          return true;
        }
        input.skip(input.length);
        await zstdMtCompressFile(region[0] as String, region[1] as int,
            region[2] as int, chosen, output,
            checksum: checksum,
            jobSize: multithread.jobSize,
            overlapLog: multithread.overlapLog,
            workers: multithread.workers ?? 0,
            memoryBudget: multithread.memoryBudget ?? zstdDefaultMemoryBudget,
            onProgress: multithread.onProgress);
        return true;
      }, false);
      return;
    }
    try {
      ZstdFrameEncoder().encodeStream(input, input.length, output,
          checksum: checksum,
          level: level ?? this.level,
          dictionary: dictionary);
    } catch (error, stack) {
      Error.throwWithStackTrace(archiveError(error, 'zstd: '), stack);
    }
  }
}

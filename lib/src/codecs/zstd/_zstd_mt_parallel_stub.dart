import 'dart:async';
import 'dart:typed_data';

import '../../util/cancellable_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/report_progress.dart';
import 'zstd_dictionary.dart';
import 'zstd_level_params.dart';
import 'zstd_mt_frame_encoder.dart';

const bool zstdIsolatesSupported = false;
const _streamPieceSize = 1 << 16;

/// Compresses the jobs in the calling isolate, all a target without [Isolate]
/// can do. The bytes are the ones the workers would have produced
Future<List<Uint8List>> zstdMtCompressJobs(
    Uint8List src, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    bool firstIsFirstJob = true,
    int size = 0,
    int paramsSize = 0,
    ZstdMtLdmPass? ldmPass,
    void Function(int consumed)? onProgress}) {
  final parts = <Uint8List>[];
  final whole = size > 0 ? size : src.length;
  // With a dictionary the parameters are sized by more than the content, and
  // the long distance pass has already run over job zero
  final sized = paramsSize > 0 ? paramsSize : whole;
  // `ZSTDMT_serialState_reset` sizes the matcher by `targetSectionSize`, the
  // job size after the minimum and the prefix raised it
  final pass = ldmPass ??
      ZstdMtLdmPass.forParams(
          zstdParamsForLevel(level, sized),
          ZstdMtFrameEncoder.geometry(level, sized,
              jobSize: jobSize, overlapLog: overlapLog)[0]);
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : src.length;
    final prefix = start < prefixSize ? start : prefixSize;
    final out = OutputMemoryStream();
    ZstdMtFrameEncoder.encodeJob(
        Uint8List.sublistView(src, start - prefix, end),
        prefix,
        out,
        level,
        sized,
        firstJob: i == 0 && firstIsFirstJob,
        lastJob: i == starts.length - 1,
        jobSize: jobSize,
        overlapLog: overlapLog,
        ldmSequences: pass?.generate(src, start, end),
        onBlock: (done) => reportProgress(onProgress, start + done));
    parts.add(out.getBytes());
    reportProgress(onProgress, end);
  }
  return Future.value(parts);
}

/// The same jobs, cut out of the arriving bytes and compressed in the calling
/// isolate, all a target without [Isolate] can do
Stream<Uint8List> zstdMtCompressStream(Stream<List<int>> input, int level,
        {required int jobSize,
        required int overlapLog,
        required int workers,
        int cap = 0,
        ZstdDictionary? dictionary,
        Uint8List Function(bool empty)? header,
        int size = zstdMtSizeUnknown,
        void Function(int consumed)? onProgress}) =>
    cancellableStream<List<int>, Uint8List>(
        input,
        (input, signal) => _compressStream(input, signal, level,
            jobSize: jobSize,
            overlapLog: overlapLog,
            dictionary: dictionary,
            header: header,
            size: size,
            onProgress: onProgress));

Stream<Uint8List> _compressStream(
    StreamIterator<List<int>> input, CancelSignal signal, int level,
    {required int jobSize,
    required int overlapLog,
    ZstdDictionary? dictionary,
    Uint8List Function(bool empty)? header,
    int size = zstdMtSizeUnknown,
    void Function(int consumed)? onProgress}) async* {
  final geometry = ZstdMtFrameEncoder.geometry(level, size,
      jobSize: jobSize, overlapLog: overlapLog);
  final ring = ZstdMtRing(geometry[0], geometry[1]);
  final ldmPass =
      ZstdMtLdmPass.forParams(zstdParamsForLevel(level, size), geometry[0]);
  var index = 0;
  var consumed = 0;
  Uint8List run(Uint8List job, bool first, bool last) {
    final before = consumed;
    consumed += job.length - (first ? 0 : geometry[1]);
    final out = OutputMemoryStream();
    var buffer = job;
    var prefix = first ? 0 : geometry[1];
    final found = ldmPass?.generate(job, first ? 0 : geometry[1], job.length);
    final dict = dictionary;
    if (first && dict != null) {
      final content = dict.content;
      buffer = Uint8List(content.length + job.length)
        ..setRange(0, content.length, content)
        ..setRange(content.length, content.length + job.length, job);
      prefix = content.length;
    }
    ZstdMtFrameEncoder.encodeJob(buffer, prefix, out, level, size,
        firstJob: first,
        lastJob: last,
        jobSize: jobSize,
        overlapLog: overlapLog,
        dictionary: first ? dict : null,
        ldmSequences: found,
        onBlock: (done) => reportProgress(onProgress, before + done));
    return out.getBytes();
  }

  Iterable<Uint8List> pieces(Uint8List bytes) sync* {
    for (var at = 0; at < bytes.length; at += _streamPieceSize) {
      final end = at + _streamPieceSize < bytes.length
          ? at + _streamPieceSize
          : bytes.length;
      yield Uint8List.sublistView(bytes, at, end);
    }
  }

  // The frame header waits for the first part, since only by then is whether
  // anything arrived at all settled
  var content = 0;
  var headerSent = false;
  while (await input.moveNext()) {
    final chunk = input.current;
    content += chunk.length;
    for (final job in ring.add(chunk)) {
      final part = run(job, index == 0, false);
      if (!headerSent) {
        headerSent = true;
        final head = header?.call(content == 0);
        if (head != null) {
          yield head;
        }
      }
      for (final piece in pieces(part)) {
        yield piece;
      }
      reportProgress(onProgress, consumed);
      index++;
    }
  }
  if (signal.cancelled) {
    return;
  }
  final tail = run(ring.close(), index == 0, true);
  if (!headerSent) {
    final head = header?.call(content == 0);
    if (head != null) {
      yield head;
    }
  }
  for (final piece in pieces(tail)) {
    yield piece;
  }
  reportProgress(onProgress, consumed);
}

/// There are no files to read from where this file is chosen
Future<List<Uint8List>> zstdMtCompressFileJobs(String path, int offset,
        int size, List<int> starts, int prefixSize, int level,
        {required int jobSize,
        required int overlapLog,
        required int workers,
        int cap = 0,
        void Function(Uint8List part)? onPart,
        void Function(int consumed)? onProgress}) =>
    throw UnsupportedError('zstd: no file access on this target');

int zstdMtFileDigest(String path, int offset, int size) =>
    throw UnsupportedError('zstd: no file access on this target');

List<Object>? zstdMtFileRegion(InputStream input) => null;

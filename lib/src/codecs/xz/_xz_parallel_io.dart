import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// The io file handle is imported directly rather than through
// file_handle.dart, whose conditional export resolves to the web class when
// the analyser has no platform in mind, and that one has no path.
import '../../util/_file_handle_io.dart';
import '../../util/byte_order.dart';
import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/input_file_stream.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'xz_index.dart';
import 'xz_multithread_options.dart';
import 'xz_stream_decoder.dart';

/// Whether this platform can decode on isolates.
const bool xzIsolatesSupported = true;

/// A stretch of a file on disk holding an xz archive.
class XZFileRegion {
  final String path;
  final int offset;
  final int length;

  const XZFileRegion(this.path, this.offset, this.length);
}

/// The file region [input] reads from, or null if it is not backed by one.
///
/// Recognising this is what lets each worker read its own block straight from
/// disk, so that the compressed data never passes through the calling isolate.
/// A stream over a file held in memory has no region and takes the ordinary
/// path.
XZFileRegion? xzFileRegionOf(InputStream input) {
  if (input is! InputFileStream) {
    return null;
  }
  final handle = input.fileBuffer.file;
  if (handle is! FileHandle) {
    return null;
  }
  return XZFileRegion(
      handle.path, input.fileOffset + input.position, input.length);
}

/// Reads the block layout of the archive in [region] without loading it.
XZLayout? xzLayoutOfFile(XZFileRegion region, {int? maxUncompressedSize}) {
  final file = File(region.path).openSync();
  try {
    return parseXZLayout(_XZFileSource(file, region.offset, region.length),
        maxUncompressedSize: maxUncompressedSize);
  } catch (_) {
    return null;
  } finally {
    file.closeSync();
  }
}

/// An [XZByteSource] that reads the ranges it is asked for from a file.
///
/// Parsing an index touches the footer, the index and the stream header, so
/// only a few kilobytes are ever read however large the archive is.
class _XZFileSource extends XZByteSource {
  final RandomAccessFile _file;
  final int _offset;

  @override
  final int length;

  _XZFileSource(this._file, this._offset, this.length);

  @override
  Uint8List range(int start, int end) {
    _file.setPositionSync(_offset + start);
    return _file.readSync(end - start);
  }
}

// Bytes a worker accumulates before shipping them back. Sending the output in
// pieces is what keeps a worker from holding a whole decoded block: for a 192
// MB block this is the difference between 192 MB and 4 MB of live memory per
// worker, at the cost of one extra memcpy of the output (~18 ms per 200 MB).
const _stagingSize = 4 * 1024 * 1024;

// The largest block header the format allows, (255 + 1) * 4.
const _maxBlockHeaderSize = 1024;

// Blocks sampled when sizing the LZMA2 dictionary. Dictionary size is a
// per-block property but is uniform in practice, and reading every header of a
// huge archive would cost more than it saves.
const _dictionarySampleLimit = 16;

const _kindStream = 0;
const _kindBlock = 1;

const _msgReady = 0;
const _msgChunk = 1;
const _msgDone = 2;

/// Decodes an xz archive across isolates, reporting the decoded bytes through
/// [onChunk].
///
/// The archive comes either from [bytes] or from the file at [path], in which
/// case [fileOffset] and [fileLength] delimit it. Reading from the file is the
/// cheaper of the two: each worker reads only the block it was given, so the
/// compressed data never passes through the calling isolate at all.
///
/// [onChunk] is handed an absolute offset into the decoded output and the
/// bytes belonging there. Chunks do not arrive in order, because blocks are
/// decoded concurrently.
///
/// [onBlockDone] reports the verdict on each block as it finishes, keyed by the
/// same output offset. A block can deliver all of its bytes and still fail,
/// which is what a mismatched check looks like, so the bytes alone do not say
/// whether they can be trusted.
///
/// [onFailureReason] is given the first reason a block was rejected, if the
/// archive turns out to be malformed. It says why the decode gave up, which
/// the false return value on its own does not.
///
/// Returns false when the archive is malformed or truncated, matching the
/// synchronous decoder. Throws only when the work could not be carried out,
/// such as an isolate failing to start.
Future<bool> xzDecodeMultithreaded({
  Uint8List? bytes,
  String? path,
  int fileOffset = 0,
  int fileLength = 0,
  required XZLayout? layout,
  required bool verify,
  required int maxPreallocateSize,
  int? workers,
  int? memoryBudget,
  required void Function(int outputOffset, Uint8List chunk) onChunk,
  void Function(int outputOffset, bool ok)? onBlockDone,
  void Function(String reason)? onFailureReason,
  bool orderedOutput = false,
  required int fileReadBufferSize,
}) {
  // Offsets in the layout are relative to the start of the archive, which sits
  // at [fileOffset] in a file and at zero in a buffer.
  final base = bytes != null ? 0 : fileOffset;
  final blocks = layout?.blocks;

  if (blocks != null && blocks.length > 1) {
    final dictionaryCap = _largestDictionaryCap(blocks, bytes, path, base);
    final count = _pickWorkerCount(
      blocks: blocks,
      requested: workers,
      memoryBudget: memoryBudget,
      dictionaryCap: dictionaryCap,
      holdsCompressedBlock: bytes != null,
      orderedOutput: orderedOutput,
      fileReadBufferSize: fileReadBufferSize,
    );
    if (count > 1) {
      return _runJobs([
        for (final block in blocks)
          _Job(
            kind: _kindBlock,
            bytes: bytes,
            path: path,
            offset: base + block.compressedOffset,
            length: block.compressedLength,
            streamFlags: block.streamFlags,
            outputOffset: block.outputOffset,
            verify: verify,
            maxPreallocateSize: maxPreallocateSize,
            fileReadBufferSize: fileReadBufferSize,
          )
      ], count, onChunk, onBlockDone, onFailureReason);
    }
  }

  // Either there is nothing worth splitting up, or the budget only allows one
  // worker. Decoding the whole archive on a single isolate is still what the
  // caller asked for: their isolate stays free.
  //
  // No per block verdict is reported here. The one job covers every block, so
  // its verdict says nothing about where a failure fell, and a caller is
  // better served working that out from the bytes that did arrive.
  return _runJobs([
    _Job(
      kind: _kindStream,
      bytes: bytes,
      path: path,
      offset: base,
      length: bytes?.length ?? fileLength,
      streamFlags: 0,
      outputOffset: 0,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      fileReadBufferSize: fileReadBufferSize,
    )
  ], 1, onChunk, null, onFailureReason);
}

/// The memory an LZMA2 dictionary will take for the largest sampled block.
///
/// This mirrors the cap [XZStreamDecoder.readBlock] sets, so that the budget
/// is measured against what a worker actually allocates rather than a guess.
int _largestDictionaryCap(
    List<XZBlockLayout> blocks, Uint8List? bytes, String? path, int base) {
  var largest = 0;
  RandomAccessFile? file;
  try {
    if (bytes == null) {
      file = File(path!).openSync();
    }
    final count = blocks.length < _dictionarySampleLimit
        ? blocks.length
        : _dictionarySampleLimit;
    for (var i = 0; i < count; i++) {
      final block = blocks[i];
      var length = block.compressedLength;
      if (length > _maxBlockHeaderSize) {
        length = _maxBlockHeaderSize;
      }
      Uint8List header;
      if (bytes != null) {
        final start = base + block.compressedOffset;
        if (start + length > bytes.length) {
          continue;
        }
        header = Uint8List.sublistView(bytes, start, start + length);
      } else {
        file!.setPositionSync(base + block.compressedOffset);
        header = file.readSync(length);
      }
      final size = xzBlockDictionarySize(header);
      if (size > largest) {
        largest = size;
      }
    }
  } catch (_) {
    // This only sizes the worker count, so a header that cannot be read falls
    // back to whatever the other blocks reported.
  } finally {
    file?.closeSync();
  }

  if (largest <= 0 || largest >= 0x40000000) {
    return 0;
  }
  return largest + (largest >> 2) + (2 << 20) + 16;
}

int _pickWorkerCount({
  required List<XZBlockLayout> blocks,
  required int? requested,
  required int? memoryBudget,
  required int dictionaryCap,
  required bool holdsCompressedBlock,
  required bool orderedOutput,
  required int fileReadBufferSize,
}) {
  final cores = Platform.numberOfProcessors;
  // One core is left to the caller; in Flutter that is the UI isolate.
  var count = requested ?? cores - 1;
  if (count > cores) {
    count = cores;
  }
  if (count < 1) {
    count = 1;
  }
  if (count > blocks.length) {
    count = blocks.length;
  }

  // A worker holds its dictionary, its staging buffer, and the compressed
  // block only when the archive came in as bytes: reading from a file it goes
  // through a small window instead. The budget applies even to an explicitly
  // requested worker count, so that it can act as a safety valve.
  var compressed = fileReadBufferSize;
  if (holdsCompressedBlock) {
    compressed = 0;
    for (final block in blocks) {
      if (block.compressedLength > compressed) {
        compressed = block.compressedLength;
      }
    }
  }

  // An output that can only be appended to has to hold back blocks that
  // finished ahead of their turn, so every worker beyond the first can leave a
  // whole decoded block waiting in the calling isolate. That is charged to the
  // worker that causes it.
  var reorder = 0;
  if (orderedOutput) {
    for (final block in blocks) {
      if (block.uncompressedLength > reorder) {
        reorder = block.uncompressedLength;
      }
    }
  }

  final perWorker = compressed + dictionaryCap + _stagingSize + reorder;
  if (perWorker > 0) {
    var affordable = (memoryBudget ?? xzDefaultMemoryBudget) ~/ perWorker;
    if (affordable < 1) {
      affordable = 1;
    }
    if (count > affordable) {
      count = affordable;
    }
  }

  return count;
}

/// One unit of work handed to a worker.
class _Job {
  final int kind;

  /// The whole archive, when it is in memory. Only [offset]..[offset]+[length]
  /// is sent to the worker.
  final Uint8List? bytes;

  final String? path;
  final int offset;
  final int length;
  final int streamFlags;
  final int outputOffset;
  final bool verify;
  final int maxPreallocateSize;
  final int fileReadBufferSize;

  const _Job({
    required this.kind,
    required this.bytes,
    required this.path,
    required this.offset,
    required this.length,
    required this.streamFlags,
    required this.outputOffset,
    required this.verify,
    required this.maxPreallocateSize,
    required this.fileReadBufferSize,
  });

  /// Builds the message for this job.
  ///
  /// The copy into external memory happens here rather than up front, so that
  /// only the blocks actually in flight are held: a queued job costs nothing
  /// beyond a view onto the archive the caller already has.
  List<Object?> toMessage() {
    TransferableTypedData? data;
    final source = bytes;
    if (source != null) {
      data = TransferableTypedData.fromList(
          [Uint8List.sublistView(source, offset, offset + length)]);
    }
    return [
      _kindMarker,
      kind,
      data,
      path,
      offset,
      length,
      streamFlags,
      outputOffset,
      verify,
      fileReadBufferSize,
      maxPreallocateSize,
    ];
  }

  // Slot 0 of a job message is unused; workers only ever receive jobs, so it
  // carries no tag. Kept so main-bound and worker-bound messages index alike.
  static const _kindMarker = 0;
}

Future<bool> _runJobs(
    List<_Job> jobs,
    int workerCount,
    void Function(int outputOffset, Uint8List chunk) onChunk,
    void Function(int outputOffset, bool ok)? onBlockDone,
    void Function(String reason)? onFailureReason) async {
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final completer = Completer<bool>();
  final pending = Queue<int>()..addAll(Iterable<int>.generate(jobs.length));

  var remaining = jobs.length;
  var ok = true;
  String? failureReason;
  Object? failure;
  StackTrace? failureStack;
  var finished = false;

  void finish() {
    if (finished) {
      return;
    }
    finished = true;
    receive.close();
    // Killing outright is safe because a worker holds no operating system
    // resources between jobs: it opens and closes the archive within one.
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    if (failureReason != null) {
      onFailureReason?.call(failureReason!);
    }
    if (failure != null) {
      completer.completeError(failure!, failureStack ?? StackTrace.current);
    } else {
      completer.complete(ok);
    }
  }

  void fail(Object error, [StackTrace? stack]) {
    failure ??= error;
    failureStack ??= stack;
    ok = false;
    finish();
  }

  receive.listen((message) {
    if (finished) {
      return;
    }
    try {
      // An isolate that dies reports through the same port, as a list whose
      // first entry is not one of the message tags. Without this the run would
      // simply never complete.
      if (message is! List || message.isEmpty || message[0] is! int) {
        fail(StateError('XZ decode isolate failed: $message'));
        return;
      }

      switch (message[0] as int) {
        case _msgChunk:
          onChunk(message[1] as int, message[2] as Uint8List);
          break;
        case _msgReady:
        case _msgDone:
          if (message[0] == _msgDone) {
            final blockOk = message[2] as bool;
            if (!blockOk) {
              ok = false;
            }
            onBlockDone?.call(message[4] as int, blockOk);
            if (!blockOk) {
              // The first block to be rejected is the one worth reporting:
              // later ones may only be failing because this one did.
              final reason = message[5];
              if (reason != null) {
                failureReason ??= reason as String;
              }
            }
            final error = message[3];
            if (error != null) {
              failure ??= StateError('XZ decode failed: $error');
            }
            remaining--;
            if (remaining == 0) {
              finish();
              return;
            }
          }
          if (pending.isNotEmpty) {
            final index = pending.removeFirst();
            (message[1] as SendPort).send(jobs[index].toMessage());
          }
          break;
      }
    } catch (error, stack) {
      fail(error, stack);
    }
  });

  try {
    for (var i = 0; i < workerCount; i++) {
      // A fast worker can get through every job before the rest of the pool
      // has even started, so the run can already be over by now.
      if (finished) {
        break;
      }
      isolates.add(await Isolate.spawn(_xzWorker, receive.sendPort,
          onError: receive.sendPort, errorsAreFatal: true));
    }
    if (finished) {
      // finish() only killed the isolates that existed when it ran.
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
  } catch (error, stack) {
    fail(error, stack);
  }

  return completer.future;
}

/// Reads the check field, which is the tail of a block.
///
/// The block padding sits in front of it and every check size is a multiple of
/// four, so the check is always the last [checkSize] bytes.
Uint8List _readCheckField(
    InputStream input, Uint8List? data, int length, int checkSize) {
  if (checkSize == 0 || length < checkSize) {
    return Uint8List(0);
  }
  if (data != null) {
    return Uint8List.sublistView(data, length - checkSize, length);
  }
  input.setPosition(length - checkSize);
  return input.readBytes(checkSize).toUint8List();
}

/// Entry point of a decode worker.
///
/// A worker outlives a single block: the pool hands it one job after another,
/// which keeps the hot LZMA loop warm. That matters under the JIT, where a
/// freshly spawned isolate has to optimise it all over again.
void _xzWorker(SendPort toMain) {
  final receive = ReceivePort();

  receive.listen((message) {
    if (message == null) {
      receive.close();
      return;
    }

    final job = message as List;
    final kind = job[1] as int;
    final transferable = job[2] as TransferableTypedData?;
    final path = job[3] as String?;
    final offset = job[4] as int;
    final length = job[5] as int;
    final streamFlags = job[6] as int;
    final outputOffset = job[7] as int;
    final verify = job[8] as bool;
    final fileReadBufferSize = job[9] as int;
    final maxPreallocateSize = job[10] as int;

    // Failing to get hold of the compressed data is a failure of the decode
    // itself rather than a statement about the archive, so it is reported as
    // an error. Anything that goes wrong afterwards is the archive's fault.
    Uint8List? data;
    InputFileStream? file;
    InputStream input;
    try {
      if (transferable != null) {
        // Materialising is free: the bytes are already in external memory and
        // this hands over ownership of them.
        data = Uint8List.view(transferable.materialize());
        input = InputMemoryStream(data);
      } else {
        // Read the block as it is decoded rather than up front. LZMA2 reads a
        // block strictly in order, so nothing is gained by holding all of it,
        // and a compressed block is the largest thing a worker would otherwise
        // keep.
        file = InputFileStream(path!, bufferSize: fileReadBufferSize);
        input = InputFileStream.fromFileStream(file,
            position: offset, length: length);
      }
    } catch (error) {
      toMain.send([
        _msgDone,
        receive.sendPort,
        false,
        error.toString(),
        outputOffset,
        null
      ]);
      return;
    }

    var ok = false;
    // Why the block was rejected, carried back so that a caller who asked to
    // be told about failures gets the reason and not just the fact.
    String? reason;
    final checkType = streamFlags & 0xf;
    // Verification is left off in the block decoder and done by the sink, on
    // the bytes as they stream past, so that verifying does not force the whole
    // block to be held in memory.
    final verifyHere = verify && kind == _kindBlock;
    final sink = _PortSink(toMain, outputOffset, verifyHere ? checkType : 0);
    try {
      if (kind == _kindBlock) {
        final result = decodeXZBlock(input, streamFlags, sink,
            maxPreallocateSize: maxPreallocateSize);
        ok = result.ok;
        reason = result.reason;
      } else {
        final decoder = XZStreamDecoder(
            verify: verify, maxPreallocateSize: maxPreallocateSize);
        ok = decoder.decode(input, sink);
        reason = decoder.failureReason;
      }
    } catch (error) {
      // A corrupt archive throws its way out of the decoder. The single
      // threaded path swallows that and reports false, and so does this one,
      // keeping the text for whoever wants to know what went wrong.
      ok = false;
      reason = '$error';
    } finally {
      // Flushing even after a failure keeps what was decoded before it, which
      // is what the single threaded path leaves in its output stream.
      try {
        sink.flush();
      } catch (error) {
        ok = false;
        reason ??= '$error';
      }
    }

    if (ok && verifyHere) {
      try {
        ok = sink.checkMatches(
            _readCheckField(input, data, length, xzCheckSize(checkType)));
        if (!ok) {
          reason = 'Block check failed';
        }
      } catch (error) {
        ok = false;
        reason = '$error';
      }
    }

    file?.closeSync();
    toMain.send([_msgDone, receive.sendPort, ok, null, outputOffset, reason]);
  });

  toMain.send([_msgReady, receive.sendPort, null, null, -1, null]);
}

/// An [OutputStream] that ships what it is given back to the calling isolate.
///
/// Writes are buffered into a fixed staging area and sent whenever it fills,
/// so the worker never holds more than [_stagingSize] of decoded output.
/// [SendPort.send] serialises eagerly, so the staging buffer is safe to reuse
/// the moment it returns.
class _PortSink extends OutputStream {
  final SendPort _port;
  final int _outputOffset;

  /// Check type to accumulate, or 0 to accumulate nothing.
  final int _checkType;

  final Uint8List _staging = Uint8List(_stagingSize);
  int _staged = 0;
  int _emitted = 0;
  int _crc = 0;

  _PortSink(this._port, this._outputOffset, this._checkType)
      : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _emitted + _staged;

  @override
  void writeByte(int value) {
    if (_staged == _stagingSize) {
      flush();
    }
    _staging[_staged++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    if (length <= 0) {
      return;
    }

    // A write larger than the staging area goes straight out. This is the path
    // a BCJ filtered block takes: the block decoder buffers such a block itself
    // and hands it over in one call, and copying it through staging would gain
    // nothing.
    if (length >= _stagingSize) {
      flush();
      _emit(bytes is Uint8List
          ? Uint8List.sublistView(bytes, 0, length)
          : Uint8List.fromList(bytes.sublist(0, length)));
      return;
    }

    if (_staged + length > _stagingSize) {
      flush();
    }
    _staging.setRange(_staged, _staged + length, bytes);
    _staged += length;
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void flush() {
    if (_staged == 0) {
      return;
    }
    _emit(Uint8List.sublistView(_staging, 0, _staged));
    _staged = 0;
  }

  void _emit(Uint8List view) {
    if (view.isEmpty) {
      return;
    }
    if (_checkType == 0x1) {
      _crc = getCrc32(view, _crc);
    } else if (_checkType == 0x4 && isCrc64Supported()) {
      _crc = getCrc64(view, _crc);
    }
    _port.send([_msgChunk, _outputOffset + _emitted, view]);
    _emitted += view.length;
  }

  /// Compares the accumulated checksum with the [checkField] stored in the
  /// block. Check types that cannot be verified pass.
  bool checkMatches(Uint8List checkField) {
    if (_checkType != 0x1 && _checkType != 0x4) {
      return true;
    }
    if (_checkType == 0x4 && !isCrc64Supported()) {
      return true;
    }
    if (checkField.isEmpty) {
      return false;
    }

    var expected = 0;
    for (var i = checkField.length - 1; i >= 0; i--) {
      expected = (expected << 8) | checkField[i];
    }
    return expected == _crc;
  }

  @override
  void clear() =>
      throw UnsupportedError('An xz worker sink cannot be rewritten');

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('An xz worker sink cannot be read back');

  @override
  void writeBackReference(int distance, int count) =>
      throw UnsupportedError('An xz worker sink cannot be read back');
}

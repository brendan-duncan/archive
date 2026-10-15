import 'dart:async';
import 'dart:typed_data';

import '../util/_limited_output_stream.dart';
import '../util/archive_exception.dart';
import '../util/chunked_sink.dart';
import '../util/decode_guard.dart';
import '../util/input_decode_stream.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'xz/_xz_no_result.dart';
import 'xz/xz_chunked.dart';
import 'xz/xz_index.dart';
import 'xz/xz_multithread_options.dart';
import 'xz/xz_parallel.dart';
import 'xz/xz_stream_decoder.dart';

// [XZMultithreadOptions] appears in the signature of both decode methods, so
// it travels with them rather than having to be imported separately.
export 'xz/xz_multithread_options.dart';

/// Decodes on the calling isolate. Pass an [XZMultithreadOptions] to spread
/// the work over isolates, one xz block at a time
/// {@macro archive.multithreaded_examples}
class XZDecoder {
  /// {@macro archive.header_size_trust}
  ///
  /// The default is much lower on the web. A failed allocation there kills the
  /// page instead of throwing
  final int maxPreallocateSize;

  /// {@macro archive.xz.max_dictionary_size}
  final int maxDictionarySize;

  XZDecoder({int? maxPreallocateSize, int? maxDictionarySize})
      : maxPreallocateSize = maxPreallocateSize ?? xzDefaultMaxPreallocateSize,
        maxDictionarySize = maxDictionarySize ?? xzDefaultMaxDictionarySize {
    if (this.maxPreallocateSize < 0) {
      throw ArgumentError.value(
          maxPreallocateSize, 'maxPreallocateSize', 'Must not be negative');
    }
    if (this.maxDictionarySize < 0) {
      throw ArgumentError.value(
          maxDictionarySize, 'maxDictionarySize', 'Must not be negative');
    }
  }

  /// Decompress the given [bytes] with the xz format.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// Splitting only helps if the archive has several blocks. That is what
  /// `xz --block-size=...` writes. Measured on 1.1 GB in six 192 MB blocks:
  ///
  /// | call | peak memory | time |
  /// |---|---|---|
  /// | no `multithread` | 3.0 GB | 16.7 s |
  /// | with `multithread` | 3.9 GB | 8.0 s |
  /// | with `multithread`, six workers | 4.4 GB | 5.1 s |
  /// See `XZMultithreadOptions` for more details
  ///
  /// {@macro archive.max_output_size.bytes}
  Uint8List decodeBytes(List<int> data,
      {bool verify = false,
      bool? throwOnError,
      int? maxOutputSize,
      XZMultithreadOptions<Uint8List>? multithread}) {
    _checkMaxOutputSize(maxOutputSize);
    final strict = throwOnError ?? verify;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);

    if (multithread == null) {
      return _decodeBytes(bytes, verify, strict, maxOutputSize);
    }
    _checkOptions(multithread, strict);

    if (!xzIsolatesSupported) {
      // No isolates here, so this blocks the caller, but the result is still
      // delivered the way the caller asked for it.
      _report(
          multithread,
          () => _decodeBytes(bytes, verify, strict, maxOutputSize),
          Uint8List(0));
      return Uint8List(0);
    }

    _reportAsync(
        multithread,
        () => _decodeBytesOnIsolates(
            bytes, verify, strict, maxOutputSize, multithread),
        Uint8List(0),
        verify,
        strict);
    return Uint8List(0);
  }

  /// Decompress the given [input] with the xz format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// | input, output | peak memory | time |
  /// |---|---|---|
  /// | `InputFileStream`, `OutputFileStream`, no `multithread` | 0.4 GB | 17.6 s |
  /// | `InputFileStream`, `OutputFileStream` | 0.9 GB | 8.1 s |
  /// | `InputFileStream`, `OutputFileStream`, six workers | 1.3 GB | 5.1 s |
  /// | `InputMemoryStream`, `OutputFileStream` | 2.6 GB | 10.1 s |
  /// See `XZMultithreadOptions` for more details
  ///
  /// {@macro archive.max_output_size.stream}
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false,
      bool? throwOnError,
      int? maxOutputSize,
      XZMultithreadOptions<bool>? multithread}) {
    _checkMaxOutputSize(maxOutputSize);
    final strict = throwOnError ?? verify;
    if (multithread == null) {
      return _decodeStream(input, output, verify, strict, maxOutputSize);
    }
    _checkOptions(multithread, strict);

    if (!xzIsolatesSupported) {
      _report(
          multithread,
          () => _decodeStream(input, output, verify, strict, maxOutputSize),
          false);
      return false;
    }

    _reportAsync(
        multithread,
        () => _decodeStreamOnIsolates(
            input, output, verify, strict, maxOutputSize, multithread),
        false,
        verify,
        strict);
    return false;
  }

  /// {@macro archive.decode_lazy}
  ///
  /// [verify] checks each block against its check as the block ends.
  InputStream decodeLazy(InputStream input, {bool verify = false}) =>
      InputDecodeStream(ChunkedSinkDecoder(
          input,
          (output) => XzChunkedDecoder(output,
              verify: verify, maxDictionarySize: maxDictionarySize)));

  /// Gets uncompressed size of XZ archive, if it's valid. When archive
  /// is not valid, return value is null. May be used with [decodeStream]
  /// for memory efficiency.
  ///
  /// ```dart
  /// final Uint8List from = Uint8List(0); // your archive
  /// final OutputMemoryStream output = OutputMemoryStream(size: XZDecoder().uncompressedSize(from));
  /// final bool ok = XZDecoder().decodeStream(InputMemoryStream(from), output);
  /// if (!ok) throw 'XZ decode failed';
  /// return output.getBytes();
  /// ```
  int? uncompressedSize(List<int> data) => _uSize(
      data is Uint8List ? data : Uint8List.fromList(data), maxPreallocateSize);

  // The single threaded decode, which is also what the multithreaded path
  // falls back to when there are no isolates.
  Uint8List _decodeBytes(
      Uint8List bytes, bool verify, bool throwOnError, int? maxOutputSize) {
    // The stream indexes give the output size up front, which avoids growing
    // the output buffer while decoding. A zero size is left to the default
    // because the buffer cannot grow out of an empty allocation.
    var size = _uSize(bytes, maxPreallocateSize);
    if (size != null && size > bytes.length * _maxPreallocateRatio) {
      size = bytes.length * _maxPreallocateRatio;
    }
    if (size != null && maxOutputSize != null && size > maxOutputSize) {
      size = maxOutputSize;
    }
    final OutputMemoryStream output =
        OutputMemoryStream(size: size != null && size > 0 ? size : null);

    _decodeStream(
        InputMemoryStream(bytes), output, verify, throwOnError, maxOutputSize);
    return output.getBytes();
  }

  // An index that declares more output than maxOutputSize is refused before
  // any worker starts
  static void _checkLayoutSize(XZLayout? layout, int? maxOutputSize) {
    if (maxOutputSize != null &&
        layout != null &&
        layout.uncompressedSize > maxOutputSize) {
      throw _LimitExceeded(ArchiveLimitException(
          'The decoded data is larger than the $maxOutputSize bytes allowed'));
    }
  }

  // guardDecode in _reportAsync turns an ArchiveException into an empty result
  // without throwOnError, so an exceeded maxOutputSize is thrown as
  // _LimitExceeded and reaches onError like the single threaded throw
  static Future<T> _limitAsync<T>(
      LimitedOutputStream? limited, Future<T> work) async {
    final T result;
    try {
      result = await work;
    } catch (_) {
      _throwIfExceeded(limited);
      rethrow;
    }
    _throwIfExceeded(limited);
    return result;
  }

  static void _throwIfExceeded(LimitedOutputStream? limited) {
    if (limited != null && limited.exceeded) {
      throw _LimitExceeded(
          ArchiveLimitException('The decoded data is larger than '
              'the ${limited.maxLength} bytes allowed'));
    }
  }

  // The most a byte of xz is taken to decode to when sizing a buffer from
  // what the index claims. Real archives of repetitive data reach about
  // 7000:1; a larger claim is let grow as the data arrives instead.
  static const int _maxPreallocateRatio = 8192;

  static void _checkMaxOutputSize(int? maxOutputSize) {
    if (maxOutputSize != null && maxOutputSize < 0) {
      throw ArgumentError.value(maxOutputSize, 'maxOutputSize', 'is negative');
    }
  }

  bool _decodeStream(InputStream input, OutputStream output, bool verify,
          bool throwOnError, int? maxOutputSize) =>
      decodeLimited(
          output,
          maxOutputSize,
          (output) =>
              _decodeStreamUnlimited(input, output, verify, throwOnError));

  bool _decodeStreamUnlimited(
      InputStream input, OutputStream output, bool verify, bool throwOnError) {
    final decoder = XZStreamDecoder(
        verify: verify,
        maxPreallocateSize: maxPreallocateSize,
        maxDictionarySize: maxDictionarySize);
    return guardDecode('XZ', verify, throwOnError, () {
      try {
        if (decoder.decode(input, output)) return true;
      } catch (error) {
        if (isDecodeCallbackError(error)) {
          rethrow;
        }
        if (!isDecodeDataError(error)) {
          rethrow;
        }
        throw ArchiveException('Invalid XZ archive: $error');
      }
      // The decoder records why it gave up, so the exception can say more than
      // that something was wrong somewhere.
      throw _invalid(decoder.failureReason, verify);
    });
  }

  // The exception a rejected archive turns into, naming the reason when the
  // decoder managed to identify one.
  static ArchiveException _invalid(String? reason, bool verify) {
    final message =
        reason == null ? 'Invalid XZ archive' : 'Invalid XZ archive: $reason';
    if (xzIsLimitFailure(reason)) {
      return ArchiveLimitException(message);
    }
    return xzIsCheckFailure(reason, verify)
        ? ArchiveChecksumException(message)
        : ArchiveException(message);
  }

  Future<Uint8List> _decodeBytesOnIsolates(
      Uint8List bytes,
      bool verify,
      bool throwOnError,
      int? maxOutputSize,
      XZMultithreadOptions<Uint8List> options) async {
    // No ceiling here: the layout only says where the blocks are, which is what
    // decides whether the work can be split up, and reading it allocates
    // nothing. The ceiling belongs to the buffer decision below.
    final layout = parseXZLayout(XZMemorySource(bytes));
    _checkLayoutSize(layout, maxOutputSize);

    if (layout == null ||
        layout.uncompressedSize > maxPreallocateSize ||
        layout.uncompressedSize > bytes.length * _maxPreallocateRatio) {
      // Either the archive has no readable index, or it claims an output too
      // large to take on trust. The index is part of the archive, so a hostile
      // one can claim any size at all; growing the buffer as the bytes actually
      // arrive is what makes that claim harmless.
      //
      // Blocks still decode in parallel when the layout is known. They finish
      // out of order and an OutputMemoryStream only appends, so the ones that
      // run ahead wait their turn in the ordered writer.
      final memory = OutputMemoryStream();
      final limited = maxOutputSize == null
          ? null
          : LimitedOutputStream(memory, maxOutputSize);
      final OutputStream output = limited ?? memory;
      final writer =
          layout == null ? null : _OrderedWriter(output, layout.blocks);
      String? reason;
      final ok = await _limitAsync(
          limited,
          xzDecodeMultithreaded(
            bytes: bytes,
            layout: layout,
            verify: verify,
            maxPreallocateSize: maxPreallocateSize,
            maxDictionarySize: maxDictionarySize,
            workers: options.workers,
            memoryBudget: options.memoryBudget,
            onChunk: writer == null
                ? (offset, chunk) => output.writeBytes(chunk)
                : writer.add,
            onBlockDone: writer?.blockDone,
            onFailureReason: (r) => reason = r,
            orderedOutput: writer != null,
            fileReadBufferSize: options.fileReadBufferSize,
          ));
      if (!ok) {
        throwIfStrict(_invalid(reason, verify), verify, throwOnError);
      }
      // Whether or not it succeeded, this yields what was decoded, which is
      // what the single threaded path does too.
      return memory.getBytes();
    }

    final blocks = layout.blocks;
    final output = Uint8List(layout.uncompressedSize);
    // How much of each block arrived, and whether it can be trusted, so that a
    // failure can still report the part of the output that is good. Blocks are
    // taken as trustworthy unless a verdict says otherwise, because verdicts
    // only arrive when the archive was split up block by block.
    final received = List<int>.filled(blocks.length, 0);
    final accepted = List<bool>.filled(blocks.length, true);
    String? reason;
    // Set when a block produced more than the index accounted for, which is the
    // archive contradicting itself.
    var overran = false;

    final ok = await xzDecodeMultithreaded(
      bytes: bytes,
      layout: layout,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      maxDictionarySize: maxDictionarySize,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: (offset, chunk) {
        // A block header can declare more output than the index records for
        // that block, and a damaged one often does. The buffer is sized from
        // the index, so the surplus has nowhere to go. Keep what fits and mark
        // the decode failed, rather than letting setRange throw: this runs in a
        // callback, so the error would surface as a bare RangeError even when
        // the caller asked for failures to be reported by return value.
        //
        // The surplus is not decoded output that is being thrown away. The two
        // sizes disagree, so the archive is invalid whichever is believed, and
        // the index is the one the buffer was allocated against. Believing the
        // block header instead would let a corrupt one demand any allocation it
        // likes, which is what maxPreallocateSize exists to prevent.
        var length = chunk.length;
        if (offset + length > output.length) {
          length = output.length - offset;
          overran = true;
          reason ??= "Uncompressed data doesn't match the length in the index";
        }
        if (length <= 0) {
          return;
        }
        output.setRange(
            offset, offset + length, Uint8List.sublistView(chunk, 0, length));
        if (blocks.isNotEmpty) {
          final index = _blockIndexAt(blocks, offset);
          received[index] += length;
          if (overran) {
            // Stops the prefix below at this block: it filled its share of the
            // output, so it would otherwise pass for whole and sound.
            accepted[index] = false;
          }
        }
      },
      onBlockDone: (index, blockOk) {
        accepted[index] = accepted[index] && blockOk;
      },
      onFailureReason: (r) => reason = r,
      fileReadBufferSize: options.fileReadBufferSize,
    );

    if (ok && !overran) {
      return output;
    }
    throwIfStrict(_invalid(reason, verify), verify, throwOnError);

    // Blocks are decoded out of order, so the output stops where the single
    // threaded decode would have given up: at the first block that is not
    // whole and sound, that block included. A block that failed part way
    // through contributes what it managed, since chunks within one block
    // arrive in order. A block that produced everything and then failed its
    // check contributes all of it, because that is what writing straight
    // through to an output stream leaves behind, and a decode that cannot be
    // undone is what the single threaded path is. The bytes are not vouched
    // for either way: the decode reported failure.
    var end = 0;
    for (var i = 0; i < blocks.length; i++) {
      final whole = received[i] == blocks[i].uncompressedLength;
      if (!whole) {
        end = blocks[i].outputOffset + received[i];
        break;
      }
      end = blocks[i].outputOffset + blocks[i].uncompressedLength;
      if (!accepted[i]) {
        break;
      }
    }
    return Uint8List.sublistView(output, 0, end);
  }

  Future<bool> _decodeStreamOnIsolates(
      InputStream input,
      OutputStream output,
      bool verify,
      bool throwOnError,
      int? maxOutputSize,
      XZMultithreadOptions<bool> options) async {
    final region = xzFileRegionOf(input);
    final limited = maxOutputSize == null
        ? null
        : LimitedOutputStream(output, maxOutputSize);

    XZLayout? layout;
    Uint8List? bytes;
    if (region != null) {
      layout = xzLayoutOfFile(region);
    } else if (input is InputMemoryStream) {
      bytes = input.toUint8List();
      layout = parseXZLayout(XZMemorySource(bytes));
    } else {
      // Any other stream has no random access to give the workers, so it is
      // decoded on the calling isolate.
      return _limitAsync(
          limited,
          Future.sync(() => _decodeStreamUnlimited(
              input, limited ?? output, verify, throwOnError)));
    }
    _checkLayoutSize(layout, maxOutputSize);

    // An OutputStream can only be appended to, so blocks that finish early are
    // held back until the blocks in front of them have been written.
    final writer = _OrderedWriter(limited ?? output, layout?.blocks);
    String? reason;

    final ok = await _limitAsync(
        limited,
        xzDecodeMultithreaded(
          bytes: bytes,
          path: region?.path,
          fileOffset: region?.offset ?? 0,
          fileLength: region?.length ?? 0,
          layout: layout,
          verify: verify,
          maxPreallocateSize: maxPreallocateSize,
          maxDictionarySize: maxDictionarySize,
          workers: options.workers,
          memoryBudget: options.memoryBudget,
          onChunk: writer.add,
          onBlockDone: layout == null ? null : writer.blockDone,
          onFailureReason: (r) => reason = r,
          orderedOutput: true,
          fileReadBufferSize: options.fileReadBufferSize,
        ));
    if (ok) {
      input.skip(input.length);
    }
    if (!ok) {
      throwIfStrict(_invalid(reason, verify), verify, throwOnError);
    }
    return ok;
  }

  // Runs [work] now and hands the result to [options.onDone], routing a
  // failure to [options.onError].
  static void _report<T>(
      XZMultithreadOptions<T> options, T Function() work, T onFailure) {
    T result;
    try {
      result = work();
    } catch (error, stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(error, stack);
      } else {
        options.onDone(onFailure);
      }
      return;
    }
    options.onDone(result);
  }

  // As [_report], for work that finishes later.
  static void _reportAsync<T>(XZMultithreadOptions<T> options,
      Future<T> Function() work, T onFailure, bool verify, bool throwOnError) {
    unawaited(work().then(options.onDone,
        onError: (Object failure, StackTrace trace) {
      if (failure is _LimitExceeded) {
        final onError = options.onError;
        if (onError != null) {
          onError(failure.error, trace);
        } else {
          options.onDone(onFailure);
        }
        return;
      }
      try {
        guardDecode('XZ', verify, throwOnError,
            () => Error.throwWithStackTrace(failure, trace));
      } catch (error, stack) {
        final onError = options.onError;
        if (onError != null) {
          onError(error, stack);
        } else {
          // Nothing would observe an unhandled asynchronous error, so the
          // failure is reported the same way an invalid archive is.
          options.onDone(onFailure);
        }
        return;
      }
      options.onDone(onFailure);
    }));
  }

  // Generic so that onDone reads back at its own type and not Object?, which a
  // function taking Uint8List is not
  static void _checkOptions<T>(XZMultithreadOptions<T> options, bool strict) {
    if (identical(options.onDone, xzNoResult)) {
      throw ArgumentError.value(
          null,
          'onDone',
          'Must be given here, since this call has nowhere else to put the '
              'result; only the converter carries its own end');
    }
    // Asking to hear about failures with nowhere to tell would send the
    // failure back where it started. It is refused before the call returns
    if (strict && options.onError == null) {
      throw ArgumentError.value(
          null,
          'onError',
          'Must be given when throwOnError is set, since that is '
              'where the exception is delivered');
    }
    final workers = options.workers;
    if (workers != null && workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
    }
    final budget = options.memoryBudget;
    if (budget != null && budget < 1) {
      throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
    }
    if (options.fileReadBufferSize < 1) {
      throw ArgumentError.value(options.fileReadBufferSize,
          'fileReadBufferSize', 'Must be at least 1');
    }
  }
}

/// Writes chunks to an append-only [OutputStream] in offset order.
class _OrderedWriter {
  final OutputStream _output;
  final List<XZBlockLayout>? _blocks;
  final _waiting = <int, Uint8List>{};
  final _confirmed = <int>{};
  int _written = 0;
  int? _stop;

  _OrderedWriter(this._output, [this._blocks]);

  void add(int offset, Uint8List chunk) {
    final stop = _stop;
    if (stop != null && offset >= stop) {
      return;
    }
    if (offset != _written || !_open(offset)) {
      _waiting[offset] = chunk;
      return;
    }

    _output.writeBytes(chunk);
    _written += chunk.length;

    // Writing this chunk may have joined up chunks that arrived before it.
    _drain();
  }

  void blockDone(int index, bool ok) {
    final blocks = _blocks!;
    if (!ok) {
      final stop = _stop;
      final end = blocks[index].outputOffset + blocks[index].uncompressedLength;
      if (stop == null || end < stop) {
        _stop = end;
      }
      _waiting.removeWhere((at, _) => at >= _stop!);
      return;
    }
    _confirmed.add(index);
    _drain();
  }

  void _drain() {
    while (_open(_written)) {
      final next = _waiting.remove(_written);
      if (next == null) {
        return;
      }
      _output.writeBytes(next);
      _written += next.length;
    }
  }

  bool _open(int offset) {
    final blocks = _blocks;
    if (blocks == null || offset == 0) {
      return true;
    }
    final index = _blockIndexAt(blocks, offset);
    if (blocks[index].outputOffset != offset) {
      return true;
    }
    for (var i = index - 1; i >= 0; i--) {
      if (!_confirmed.contains(i)) {
        return false;
      }
      if (blocks[i].outputOffset != offset) {
        break;
      }
    }
    return true;
  }
}

/// The index of the block that [offset] falls in.
int _blockIndexAt(List<XZBlockLayout> blocks, int offset) {
  var low = 0;
  var high = blocks.length - 1;
  while (low < high) {
    final middle = (low + high + 1) >> 1;
    if (blocks[middle].outputOffset <= offset) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

/// Default for [XZDecoder.maxPreallocateSize].
///
/// tood: reconsider wasm
/// 2 GB where a failed allocation is survivable. 256 MB on the web. dart2js
/// and dart2wasm kill the page instead of throwing something catchable.
/// dart2wasm cannot reach 1 GB at all. 256 MB stays under that
final int xzDefaultMaxPreallocateSize =
    xzIsolatesSupported ? 1 << 31 : 256 * 1024 * 1024;

class _LimitExceeded {
  final ArchiveException error;

  const _LimitExceeded(this.error);
}

// Returns the total uncompressed size of every stream in [d], taken from the
// stream indexes, or null if it cannot be determined or exceeds [maxSize].
int? _uSize(Uint8List d, int maxSize) =>
    parseXZLayout(XZMemorySource(d), maxUncompressedSize: maxSize)
        ?.uncompressedSize;

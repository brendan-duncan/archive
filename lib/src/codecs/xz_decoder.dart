import 'dart:async';
import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'xz/xz_index.dart';
import 'xz/xz_multithread_options.dart';
import 'xz/xz_parallel.dart';
import 'xz/xz_stream_decoder.dart';

// [XZMultithreadOptions] appears in the signature of both decode methods, so
// it travels with them rather than having to be imported separately.
export 'xz/xz_multithread_options.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decompress data with the xz format decoder.
///
/// Both methods decode on the calling isolate by default. Passing an
/// [XZMultithreadOptions] instead spreads the work over isolates, one xz block
/// at a time; see the notes on each method for what that costs in memory.
class XZDecoder {
  /// Largest output, in bytes, that will be allocated up front on the strength
  /// of what an archive's stream index claims.
  ///
  /// The index is part of the archive, so the size in it is only as trustworthy
  /// as whoever produced the file. Ratios above 6000:1 are ordinary for
  /// repetitive data, so a small archive can honestly describe an output of
  /// hundreds of gigabytes, and a hostile one can describe an output that is
  /// not there at all. Beyond this the claim is not acted on: the buffer grows
  /// as the bytes actually arrive, which costs some copying and makes an
  /// inflated claim harmless. Decoding is not capped by it, nor is splitting
  /// the work across isolates, and [uncompressedSize] returns null above it
  /// rather than a number this decoder would not act on.
  ///
  /// The default is [xzDefaultMaxPreallocateSize], which is far lower on the
  /// web because a failed allocation there kills the page instead of throwing.
  /// Raise it where the memory is known to be there, lower it where a hostile
  /// archive is a real possibility.
  final int maxPreallocateSize;

  XZDecoder({int? maxPreallocateSize})
      : maxPreallocateSize = maxPreallocateSize ?? xzDefaultMaxPreallocateSize {
    if (this.maxPreallocateSize < 0) {
      throw ArgumentError.value(
          maxPreallocateSize, 'maxPreallocateSize', 'Must not be negative');
    }
  }

  /// Decompress the given [bytes] with the xz format.
  ///
  /// A malformed or truncated archive yields whatever was decoded before the
  /// failure, with nothing to say that it is not the whole file. Set
  /// [throwOnError] to get an [ArchiveException] instead, which is the only
  /// way this method can report a failure: unlike [decodeStream] it has no
  /// return value to spare for one.
  ///
  /// [verify] checks the checksum stored with each block, catching damage that
  /// decodes without complaint. It costs time and changes only whether a
  /// failure is noticed, never what a successful decode returns. A block whose
  /// check does not match is a failure like any other, so without
  /// [throwOnError] the result is still the bytes up to and including it,
  /// exactly as [decodeStream] would have left them in its output.
  ///
  /// [throwOnError] governs how a bad *archive* is reported and nothing else.
  /// Arguments that cannot be honoured throw [ArgumentError] whichever way it
  /// is set, and so does [maxPreallocateSize] on this class.
  ///
  /// Pass [multithread] to decode on isolates. The call then returns
  /// immediately, **the return value is an empty list**, and the result
  /// arrives through [XZMultithreadOptions.onDone]:
  ///
  /// ```dart
  /// final completer = Completer<Uint8List>();
  /// XZDecoder().decodeBytes(compressed,
  ///     multithread: XZMultithreadOptions(onDone: completer.complete));
  /// final data = await completer.future;
  /// ```
  ///
  /// [throwOnError] keeps working there. The exception cannot be thrown at the
  /// caller, whose stack is long gone by then, so it is handed to
  /// [XZMultithreadOptions.onError] instead, and [XZMultithreadOptions.onDone]
  /// is not called at all. Without [throwOnError] a failed decode reaches
  /// [XZMultithreadOptions.onDone] as the partial output, exactly as it is
  /// returned here.
  ///
  /// Multithreading only pays off for an archive written in several blocks,
  /// which is what `xz --block-size=...` produces; a single block archive
  /// cannot be split and is simply decoded on one isolate. Measured on a 1.1
  /// GB archive of six 192 MB blocks:
  ///
  /// | call | peak memory | time |
  /// |---|---|---|
  /// | no `multithread` | 3.0 GB | 16.7 s |
  /// | with `multithread` | 3.9 GB | 8.0 s |
  /// | with `multithread`, six workers | 4.4 GB | 5.1 s |
  ///
  /// This is the more expensive of the two methods, and by some distance: the
  /// archive and the decoded output both stay in memory, and every worker holds
  /// a copy of the block it is decoding, because bytes handed over cannot be
  /// read from anywhere else. [decodeStream] over an `InputFileStream` and an
  /// `OutputFileStream` decodes the same archive in the same time using well
  /// under a third of the memory, and is worth preferring whenever the data is
  /// on disk anyway.
  ///
  /// The default [XZMultithreadOptions.memoryBudget] allowed three workers
  /// here; raising it buys the six worker row.
  Uint8List decodeBytes(List<int> data,
      {bool verify = false,
      bool throwOnError = false,
      XZMultithreadOptions<Uint8List>? multithread}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);

    if (multithread == null) {
      return _decodeBytes(bytes, verify, throwOnError);
    }
    _checkOptions(multithread, throwOnError);

    if (!xzIsolatesSupported) {
      // No isolates here, so this blocks the caller, but the result is still
      // delivered the way the caller asked for it.
      _report(multithread, () => _decodeBytes(bytes, verify, throwOnError),
          Uint8List(0));
      return Uint8List(0);
    }

    _reportAsync(
        multithread,
        () => _decodeBytesOnIsolates(bytes, verify, throwOnError, multithread),
        Uint8List(0));
    return Uint8List(0);
  }

  /// Decompress the given [input] with the xz format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// Returns false if the archive is malformed or truncated, in which case
  /// [output] holds however much was decoded before the failure and should be
  /// discarded. Set [throwOnError] to get an [ArchiveException] instead; the
  /// partial data is in [output] either way, because bytes already written
  /// there cannot be taken back.
  ///
  /// [verify] checks the checksum stored with each block, catching damage that
  /// decodes without complaint. It costs time and changes only whether a
  /// failure is noticed, never what a successful decode writes.
  ///
  /// [throwOnError] governs how a bad *archive* is reported and nothing else.
  /// Arguments that cannot be honoured throw [ArgumentError] whichever way it
  /// is set, and so does [maxPreallocateSize] on this class.
  ///
  /// Pass [multithread] to decode on isolates. The call then returns
  /// immediately, **the return value is always false**, and the outcome
  /// arrives through [XZMultithreadOptions.onDone]. [throwOnError] keeps
  /// working there, except that the exception cannot be thrown at the caller,
  /// whose stack is long gone by then: it is handed to
  /// [XZMultithreadOptions.onError] instead, and [XZMultithreadOptions.onDone]
  /// is not called at all.
  ///
  /// This is the cheaper of the two methods, and the combination of streams
  /// decides how cheap. When [input] is an `InputFileStream`, each worker
  /// reads its own block from the file as it decodes it, so neither the
  /// archive nor any block of it is ever held whole. Measured on a 1.1 GB
  /// archive of six 192 MB blocks, at the default memory budget:
  ///
  /// | input, output | peak memory | time |
  /// |---|---|---|
  /// | `InputFileStream`, `OutputFileStream`, no `multithread` | 0.4 GB | 17.6 s |
  /// | `InputFileStream`, `OutputFileStream` | 0.9 GB | 8.1 s |
  /// | `InputFileStream`, `OutputFileStream`, six workers | 1.3 GB | 5.1 s |
  /// | `InputMemoryStream`, `OutputFileStream` | 2.6 GB | 10.1 s |
  ///
  /// Note the first row: file to file without [multithread] holds nothing but
  /// the LZMA dictionary and the two stream buffers, which no multithreaded
  /// run can match, since each worker needs a dictionary of its own. Every row
  /// below it buys time with memory. That is the trade to make deliberately,
  /// and on a drive with a seek penalty it may not be a trade at all: workers
  /// read different parts of the file at once, so a single threaded sweep can
  /// win outright. See [XZMultithreadOptions.fileReadBufferSize].
  ///
  /// An [input] that is neither of those has no random access to hand the
  /// workers, so it is decoded on the calling isolate and reported through
  /// [XZMultithreadOptions.onDone] like everything else.
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false,
      bool throwOnError = false,
      XZMultithreadOptions<bool>? multithread}) {
    if (multithread == null) {
      return _decodeStream(input, output, verify, throwOnError);
    }
    _checkOptions(multithread, throwOnError);

    if (!xzIsolatesSupported) {
      _report(multithread,
          () => _decodeStream(input, output, verify, throwOnError), false);
      return false;
    }

    _reportAsync(
        multithread,
        () => _decodeStreamOnIsolates(
            input, output, verify, throwOnError, multithread),
        false);
    return false;
  }

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
  Uint8List _decodeBytes(Uint8List bytes, bool verify, bool throwOnError) {
    // The stream indexes give the output size up front, which avoids growing
    // the output buffer while decoding. A zero size is left to the default
    // because the buffer cannot grow out of an empty allocation.
    final int? size = _uSize(bytes, maxPreallocateSize);
    final OutputMemoryStream output =
        OutputMemoryStream(size: size != null && size > 0 ? size : null);

    _decodeStream(InputMemoryStream(bytes), output, verify, throwOnError);
    return output.getBytes();
  }

  bool _decodeStream(
      InputStream input, OutputStream output, bool verify, bool throwOnError) {
    final decoder =
        XZStreamDecoder(verify: verify, maxPreallocateSize: maxPreallocateSize);
    try {
      if (decoder.decode(input, output)) return true;
    } catch (error) {
      if (throwOnError) throw ArchiveException('Invalid XZ archive: $error');
      return false;
    }
    // The decoder records why it gave up, so the exception can say more than
    // that something was wrong somewhere.
    if (throwOnError) throw _invalid(decoder.failureReason);
    return false;
  }

  // The exception a rejected archive turns into, naming the reason when the
  // decoder managed to identify one.
  static ArchiveException _invalid(String? reason) => ArchiveException(
      reason == null ? 'Invalid XZ archive' : 'Invalid XZ archive: $reason');

  Future<Uint8List> _decodeBytesOnIsolates(Uint8List bytes, bool verify,
      bool throwOnError, XZMultithreadOptions<Uint8List> options) async {
    // No ceiling here: the layout only says where the blocks are, which is what
    // decides whether the work can be split up, and reading it allocates
    // nothing. The ceiling belongs to the buffer decision below.
    final layout = parseXZLayout(XZMemorySource(bytes));

    if (layout == null || layout.uncompressedSize > maxPreallocateSize) {
      // Either the archive has no readable index, or it claims an output too
      // large to take on trust. The index is part of the archive, so a hostile
      // one can claim any size at all; growing the buffer as the bytes actually
      // arrive is what makes that claim harmless.
      //
      // Blocks still decode in parallel when the layout is known. They finish
      // out of order and an OutputMemoryStream only appends, so the ones that
      // run ahead wait their turn in the ordered writer.
      final output = OutputMemoryStream();
      final writer = layout == null ? null : _OrderedWriter(output);
      String? reason;
      final ok = await xzDecodeMultithreaded(
        bytes: bytes,
        layout: layout,
        verify: verify,
        maxPreallocateSize: maxPreallocateSize,
        workers: options.workers,
        memoryBudget: options.memoryBudget,
        onChunk: writer == null
            ? (offset, chunk) => output.writeBytes(chunk)
            : writer.add,
        onFailureReason: (r) => reason = r,
        orderedOutput: writer != null,
        fileReadBufferSize: options.fileReadBufferSize,
      );
      if (!ok && throwOnError) {
        throw _invalid(reason);
      }
      // Whether or not it succeeded, this yields what was decoded, which is
      // what the single threaded path does too.
      return output.getBytes();
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
      onBlockDone: (offset, blockOk) {
        if (blocks.isNotEmpty) {
          final index = _blockIndexAt(blocks, offset);
          accepted[index] = accepted[index] && blockOk;
        }
      },
      onFailureReason: (r) => reason = r,
      fileReadBufferSize: options.fileReadBufferSize,
    );

    if (ok && !overran) {
      return output;
    }
    if (throwOnError) {
      throw _invalid(reason);
    }

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
      XZMultithreadOptions<bool> options) async {
    final region = xzFileRegionOf(input);

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
      return _decodeStream(input, output, verify, throwOnError);
    }

    // An OutputStream can only be appended to, so blocks that finish early are
    // held back until the blocks in front of them have been written.
    final writer = _OrderedWriter(output);
    String? reason;

    final ok = await xzDecodeMultithreaded(
      bytes: bytes,
      path: region?.path,
      fileOffset: region?.offset ?? 0,
      fileLength: region?.length ?? 0,
      layout: layout,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: writer.add,
      onFailureReason: (r) => reason = r,
      orderedOutput: true,
      fileReadBufferSize: options.fileReadBufferSize,
    );
    if (!ok && throwOnError) {
      throw _invalid(reason);
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
  static void _reportAsync<T>(
      XZMultithreadOptions<T> options, Future<T> Function() work, T onFailure) {
    unawaited(
        work().then(options.onDone, onError: (Object error, StackTrace stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(error, stack);
      } else {
        // Nothing would observe an unhandled asynchronous error, so the
        // failure is reported the same way an invalid archive is.
        options.onDone(onFailure);
      }
    }));
  }

  // Rejects settings that cannot be honoured, rather than quietly doing
  // something else. Both of these feed the arithmetic that sizes the pool, and
  // a nonsensical value there does not fail loudly: a negative read buffer
  // makes the per worker cost come out negative, which skips the memory budget
  // altogether and hands out more workers than the budget allows.
  static void _checkOptions(
      XZMultithreadOptions<Object?> options, bool throwOnError) {
    // Asking to be told about failures while leaving nowhere to tell would put
    // the failure back where it started, so it is refused here, while the
    // caller is still on the stack to hear about it.
    if (throwOnError && options.onError == null) {
      throw ArgumentError.value(
          null,
          'onError',
          'Must be given when throwOnError is set, since that is where the '
              'exception is delivered');
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
  final _waiting = <int, Uint8List>{};
  int _written = 0;

  _OrderedWriter(this._output);

  void add(int offset, Uint8List chunk) {
    if (offset != _written) {
      _waiting[offset] = chunk;
      return;
    }

    _output.writeBytes(chunk);
    _written += chunk.length;

    // Writing this chunk may have joined up chunks that arrived before it.
    while (true) {
      final next = _waiting.remove(_written);
      if (next == null) {
        return;
      }
      _output.writeBytes(next);
      _written += next.length;
    }
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
/// Two gigabytes where allocation failure is survivable, and 256 MB on the web,
/// where it is not: dart2js and dart2wasm both kill the page outright rather
/// than throwing something catchable, and dart2wasm cannot reach a gigabyte in
/// the first place. The web figure leaves room under that.
final int xzDefaultMaxPreallocateSize =
    xzIsolatesSupported ? 1 << 31 : 256 * 1024 * 1024;

// Returns the total uncompressed size of every stream in [d], taken from the
// stream indexes, or null if it cannot be determined or exceeds [maxSize].
int? _uSize(Uint8List d, int maxSize) =>
    parseXZLayout(XZMemorySource(d), maxUncompressedSize: maxSize)
        ?.uncompressedSize;

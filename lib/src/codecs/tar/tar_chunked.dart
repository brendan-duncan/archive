import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../archive/archive_file.dart';
import '../../util/_link_target.dart';
import '../../util/_pieces.dart';
import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../../util/decode_guard.dart';
import '../../util/input_memory_stream.dart';
import '../tar_encoder.dart';
import '_tar_entry_file.dart';
import 'tar_file.dart';
import 'tar_sparse.dart';

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class TarChunkedEncoder {
  final Sink<List<int>> output;

  /// The encoding used to write the entry name, matching what
  /// [TarDecoderTransformer] uses to read it back
  final Encoding filenameEncoding;

  TarChunkedEncoder(this.output, {this.filenameEncoding = const Utf8Codec()}) {
    _encoder.start(_out);
  }

  late final _encoder = TarEncoder(filenameEncoding: filenameEncoding);
  late final _out = SinkOutputStream(output);
  var _closed = false;

  void add(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    _encoder.add(entry);
  }

  /// Writes the entry header and returns the payload stream for callers
  /// that need to provide the content piece-by-piece
  TarFile? addHeader(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    return _encoder.addHeader(entry);
  }

  /// Pushes what the header left in the buffer out to the sink, so a caller
  /// that writes the content itself writes it behind the header
  void flush() => _out.flush();

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _encoder.finish();
    output.close();
  }
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class TarCodec {
  final Encoding filenameEncoding;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const TarCodec(
      {this.filenameEncoding = const Utf8Codec(), this.autoClose = false});

  TarDecoderTransformer get decoder =>
      TarDecoderTransformer(filenameEncoding: filenameEncoding);

  TarEncoderTransformer get encoder => TarEncoderTransformer(
      filenameEncoding: filenameEncoding, autoClose: autoClose);
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
const tarCodec = TarCodec();

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class TarEncoderTransformer
    extends StreamTransformerBase<ArchiveFile, List<int>> {
  final Encoding filenameEncoding;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const TarEncoderTransformer(
      {this.filenameEncoding = const Utf8Codec(), this.autoClose = false});

  /// The chunk size used to stream the entry's payload. Since entries aren't
  /// buffered in full, the encoder yields the content in pieces of this size
  static const _piece = 64 * 1024;

  @override
  Stream<List<int>> bind(Stream<ArchiveFile> stream) => archiveStreamErrors(
      stream,
      (Stream<ArchiveFile> source) => cancellableStream<ArchiveFile, List<int>>(
          source, (input, signal) => _write(input, signal)));

  Stream<List<int>> _write(
      StreamIterator<ArchiveFile> input, CancelSignal signal) async* {
    final held = <List<int>>[];
    final encoder =
        TarChunkedEncoder(Pieces(held), filenameEncoding: filenameEncoding);
    while (await input.moveNext()) {
      final entry = input.current;
      try {
        // We process the header but leave the content raw. Yielding here lets
        // the reader start consuming the payload before the entire entry is
        // buffered
        final file = encoder.addHeader(entry);
        encoder.flush();
        while (held.isNotEmpty) {
          yield held.removeAt(0);
        }
        if (file == null) {
          continue;
        }
        final body = file.contentStream;
        if (body != null) {
          while (!body.isEOS) {
            final take = body.length < _piece ? body.length : _piece;
            // An InputStream can report a length of 0 before its end. Without
            // this check the loop yields empty pieces forever
            if (take <= 0) {
              break;
            }
            yield body.readBytes(take).toUint8List();
          }
        }
        final pad = file.padding;
        if (pad > 0) {
          yield Uint8List(pad);
        }
      } finally {
        // Runs as finally block to catch stream cancellations
        // triggered at the yield
        if (autoClose) {
          entry.closeSync();
        }
      }
    }
    if (signal.cancelled) {
      return;
    }
    encoder.close();
    while (held.isNotEmpty) {
      yield held.removeAt(0);
    }
  }
}

/// {@macro archive.codecs.not_converter}
/// {@macro archive.yield_codecs.one_at_time}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class TarDecoderTransformer extends StreamTransformerBase<List<int>, TarEntry> {
  final Encoding filenameEncoding;

  const TarDecoderTransformer({this.filenameEncoding = const Utf8Codec()});

  @override
  Stream<TarEntry> bind(Stream<List<int>> stream) => archiveStreamErrors(
      stream,
      (Stream<List<int>> source) => cancellableStream<List<int>, TarEntry>(
          source,
          (input, signal) => _read(_Reader(input), filenameEncoding, signal)));
}

/// The parsed type flag. Note that older tar files often use an empty field
/// for plain files rather than the standard '0'
enum TarEntryType {
  file,
  hardLink,
  symbolicLink,
  characterDevice,
  blockDevice,
  directory,
  fifo,
  contiguousFile,

  /// A flag this package has no name for, left to [TarEntry.typeFlag]
  other;

  static TarEntryType of(String flag) => switch (flag) {
        TarFile.normalFile || '' || '\u0000' => file,
        TarFile.hardLink => hardLink,
        TarFile.symbolicLink => symbolicLink,
        TarFile.charSpec => characterDevice,
        TarFile.blockSpec => blockDevice,
        TarFile.directory => directory,
        'D' => directory,
        TarFile.fifo => fifo,
        TarFile.contFile => contiguousFile,
        _ => other,
      };
}

/// A single tar entry parsed from a Stream
class TarEntry {
  final String name;

  /// The size specified in the header, matching the byte count of [content]
  final int size;
  final int mode;
  final int ownerId;
  final int groupId;
  final int lastModTime;

  /// The entry type. Use [typeFlag] to access raw or unmapped flags directly
  final TarEntryType type;
  final String typeFlag;
  final String? symbolicLink;

  TarEntry._(TarFile file, this._reader, {Uint8List? head, int read = 0})
      : name = file.filename,
        type = file.sparse != null || file.typeFlag == TarFile.gnuSparse
            ? TarEntryType.file
            : TarEntryType.of(file.typeFlag) == TarEntryType.file &&
                    file.filename.endsWith('/')
                ? TarEntryType.directory
                : TarEntryType.of(file.typeFlag),
        size = file.sparse?.realSize ?? file.fileSize,
        mode = file.mode,
        ownerId = file.ownerId,
        groupId = file.groupId,
        lastModTime = file.lastModTime,
        typeFlag = file.typeFlag,
        symbolicLink = !(file.nameOfLinkedFile?.isNotEmpty ?? false)
            ? null
            : file.typeFlag == TarFile.hardLink
                ? hardLinkFromFolder(file.filename, file.nameOfLinkedFile!)
                : file.nameOfLinkedFile,
        _sparse = file.sparse,
        _stored = file.fileSize,
        _head = head,
        _left = file.fileSize - read;

  final _Reader _reader;
  final TarSparse? _sparse;
  final int _stored;
  Uint8List? _head;
  int _left;
  var _taken = false;
  var _done = false;

  /// Indicates that the reader skipped over this entry's unread bytes
  var _gone = false;

  /// Resolves when the content stream stops pulling from the reader
  Future<void> _settled = Future.value();

  /// The read the content stream has in flight. On dart2wasm an async*
  /// generator runs on to its next await before a cancel reaches it, and the
  /// cancel completes before that read does, so settling has to wait for it
  Future<Uint8List>? _reading;

  Future<void> _readDone() async {
    try {
      await _reading;
    } catch (_) {
      // The content stream reports it, if anyone still listens
    }
  }

  /// A standard file only (not a link or a device)
  bool get isFile => type == TarEntryType.file;

  bool get isDirectory => type == TarEntryType.directory;

  bool get isSymbolicLink => type == TarEntryType.symbolicLink;

  /// Yields the entry's data on the fly. The bytes can only be consumed once,
  /// and only while the parser is actively on this entry
  Stream<List<int>> get content {
    if (_done) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    if (_taken) {
      throw StateError('tar: the content of $name was already read');
    }
    _taken = true;
    return _detached(_pieces());
  }

  Future<void> writeToFile(String path) async {
    if (_done) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    if (_taken) {
      throw StateError('tar: the content of $name was already read');
    }
    _taken = true;
    final settled = Completer<void>();
    _settled = settled.future;
    _finish = () {
      if (!settled.isCompleted) {
        settled.complete();
      }
    };
    try {
      await writeTarEntryFile(path, _parts());
    } finally {
      await _readDone();
      _finish!();
    }
  }

  /// Canceling [pieces] is synchronous so you can easily time out on a
  /// dead stream. Any active read is left to gracefully fail whenever its
  /// next piece arrives
  Stream<List<int>> _detached(Stream<List<int>> pieces) {
    StreamSubscription<List<int>>? inner;
    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      onListen: () {
        final settled = Completer<void>();
        _settled = settled.future;
        inner = pieces.listen(out.add, onError: out.addError, onDone: () {
          if (!settled.isCompleted) {
            settled.complete();
          }
          unawaited(out.close());
        });
        _finish = () {
          if (!settled.isCompleted) {
            settled.complete();
          }
        };
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        unawaited(inner!
            .cancel()
            .catchError((Object _) {})
            .whenComplete(_readDone)
            .whenComplete(() => _finish?.call()));
      },
    );
    return out.stream;
  }

  void Function()? _finish;

  Stream<List<int>> _pieces() async* {
    if (_gone) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    final head = _head;
    if (head != null && head.isNotEmpty) {
      _head = null;
      yield head;
    }
    final sparse = _sparse;
    if (sparse == null) {
      yield* _stream(_left);
      return;
    }
    var end = 0;
    for (final (offset, length) in sparse.regions) {
      yield* _holes(offset - end);
      yield* _stream(length);
      end = offset + length;
    }
    yield* _holes(sparse.realSize - end);
  }

  Stream<Object> _parts() async* {
    if (_gone) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    final head = _head;
    if (head != null && head.isNotEmpty) {
      _head = null;
      yield head;
    }
    final sparse = _sparse;
    if (sparse == null) {
      yield* _stream(_left);
      return;
    }
    var end = 0;
    for (final (offset, length) in sparse.regions) {
      yield offset - end;
      yield* _stream(length);
      end = offset + length;
    }
    yield sparse.realSize - end;
  }

  Stream<Uint8List> _stream(int count) async* {
    var need = count;
    while (need > 0) {
      final Uint8List piece;
      try {
        // _left drops as soon as the bytes leave the reader, not when this
        // generator resumes, which can be after a cancel has settled
        piece = await (_reading = _reader.some(need).then((piece) {
          _left -= piece.length;
          return piece;
        }));
      } catch (error, stack) {
        Error.throwWithStackTrace(sourceError(error), stack);
      }
      if (piece.isEmpty) {
        throw ArchiveException('tar: unexpected end of archive $name');
      }
      need -= piece.length;
      yield piece;
    }
  }

  static Stream<Uint8List> _holes(int count) async* {
    var need = count;
    while (need > 0) {
      final n = need < 1 << 16 ? need : 1 << 16;
      need -= n;
      yield Uint8List(n);
    }
  }
}

Stream<TarEntry> _read(
    _Reader reader, Encoding encoding, CancelSignal signal) async* {
  final metadata = TarMetadata();
  var first = true;
  try {
    while (true) {
      final header = await reader.exact(512);
      if (header == null && first) {
        throw ArchiveException('tar: unexpected end of archive');
      }
      first = false;
      // A block of zeros ends the archive; padding or another archive follows
      if (header == null || _allZero(header)) {
        break;
      }
      // Since seeking backwards isn't supported, accidentally parsing payload
      // as a header consumes and destroys that data. The checksum is the
      // sole indicator that we're looking at a real header
      if (!tarHeaderChecksumMatches(header)) {
        // A header checksum guards structure, so a mismatch is ArchiveException
        // do not remove or even slightly corrupted tar will report dozens of
        // thousands of invalid files and folders
        throw ArchiveException('tar: invalid header checksum');
      }
      if (!tarHeaderSizeIsNumber(header)) {
        throw ArchiveException('tar: invalid header size');
      }
      // The header is read again, followed immediately by its content,
      // exactly where `TarMetadata` expects to find it
      var file = TarFile.read(InputMemoryStream(header),
          storeData: false,
          encoding: encoding,
          size: metadata.dataSize,
          name: metadata.name,
          pax: metadata.pax);
      metadata.sawHeader(file);
      if (TarMetadata.describesNext(file)) {
        final body = await reader.exact(_padded(file.fileSize));
        if (body == null) {
          throw ArchiveException('tar: unexpected end of archive');
        }
        final whole = Uint8List(512 + file.fileSize)
          ..setRange(0, 512, header)
          ..setRange(512, 512 + file.fileSize, body);
        file = TarFile.read(InputMemoryStream(whole),
            storeData: false, encoding: encoding, size: metadata.size);
        final taken = metadata.take(file, encoding);
        final orphan = metadata.takeOrphan();
        if (orphan != null) {
          yield* _held(orphan, signal);
        }
        if (!taken) {
          metadata.applyTo(file);
          if (file.sparse != null) {
            file.resolveSparse(file.rawContent ?? InputMemoryStream.empty());
          }
          final orphan = metadata.takeOrphan();
          if (orphan != null) {
            yield* _held(orphan, signal);
          }
          yield* _held(file, signal);
        }
        if (signal.cancelled) {
          return;
        }
        continue;
      }
      metadata.applyTo(file);
      final sparse = file.sparse;
      Uint8List? head;
      if (sparse != null) {
        while (sparse.extended) {
          final block = await reader.exact(512);
          if (block == null) {
            throw ArchiveException('tar: unexpected end of archive');
          }
          file.readSparseExtension(InputMemoryStream(block));
        }
        if (sparse.mapInData) {
          final taken = BytesBuilder(copy: false);
          while (taken.length < file.fileSize) {
            final left = file.fileSize - taken.length;
            final block = await reader.exact(left < 512 ? left : 512);
            if (block == null) {
              throw ArchiveException('tar: unexpected end of archive');
            }
            taken.add(block);
            if (sparse.readMap(block) != null) {
              break;
            }
          }
          head = taken.takeBytes();
        }
      }
      final read = head?.length ?? 0;
      if (file.applySparse()) {
        head = null;
      } else {
        throw ArchiveException('tar: invalid sparse map');
      }
      final orphan = metadata.takeOrphan();
      if (orphan != null) {
        yield* _held(orphan, signal);
        if (signal.cancelled) {
          return;
        }
      }

      final entry = TarEntry._(file, reader, head: head, read: read);
      yield entry;
      entry._done = true;
      // A paused content read never completes on its own, so a cancel has to
      // end the wait below as well
      signal.onCancel = () => entry._finish?.call();
      // We share the reader with the active content read, meaning
      // it must complete before we can proceed
      await entry._settled;
      if (signal.cancelled) {
        return;
      }
      entry._gone = entry._left > 0;
      await reader.skip(entry._left + _padding(entry._stored));
      entry._left = 0;
    }
    final orphan = metadata.takeOrphan(true);
    if (orphan != null && !signal.cancelled) {
      yield* _held(orphan, signal);
    }
  } finally {
    await reader.cancel();
  }
}

Stream<TarEntry> _held(TarFile file, CancelSignal signal) async* {
  final bytes = file.rawContent?.toUint8List() ?? Uint8List(0);
  final read = file.sparse?.mapLength ?? 0;
  final entry = TarEntry._(
      file,
      _Reader(StreamIterator(
          Stream<List<int>>.value(Uint8List.sublistView(bytes, read)))),
      read: read);
  yield entry;
  // On dart2js and DDC this generator resumes after yield* before listener
  // receives entry, so content throws StateError. Web builds wait 1 microtask
  // before setting _done, and on VM const condition removes this await
  if (!const bool.fromEnvironment('dart.library.isolate')) {
    await Future<void>.value();
  }
  entry._done = true;
  signal.onCancel = () => entry._finish?.call();
  await entry._settled;
  entry._gone = entry._left > 0;
  entry._left = 0;
}

/// The full entry size, padded to the nearest block
int _padded(int size) => size + _padding(size);

int _padding(int size) => (512 - (size % 512)) % 512;

bool _allZero(Uint8List block) {
  for (final byte in block) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

/// Pulls a format-specified number of bytes from the `Stream`
class _Reader {
  _Reader(this._it);

  final StreamIterator<List<int>> _it;
  Uint8List _held = Uint8List(0);
  int _at = 0;

  Future<bool> _more() async {
    while (_at >= _held.length) {
      if (!await _it.moveNext()) {
        return false;
      }
      final piece = _it.current;
      _held = piece is Uint8List ? piece : Uint8List.fromList(piece);
      _at = 0;
    }
    return true;
  }

  /// Up to [max] bytes of what has arrived, empty once the input is over
  Future<Uint8List> some(int max) async {
    if (!await _more()) {
      return Uint8List(0);
    }
    var take = _held.length - _at;
    if (take > max) {
      take = max;
    }
    final piece = Uint8List.sublistView(_held, _at, _at + take);
    _at += take;
    return piece;
  }

  /// {@macro archive.header_size_trust}
  static const _reserve = 1 << 16;

  /// Exactly [count] bytes, or null if the input ended before any arrived
  Future<Uint8List?> exact(int count) async {
    if (count == 0) {
      return Uint8List(0);
    }
    var out = Uint8List(count < _reserve ? count : _reserve);
    var got = 0;
    while (got < count) {
      final piece = await some(count - got);
      if (piece.isEmpty) {
        if (got == 0) {
          return null;
        }
        throw ArchiveException('tar: unexpected end of archive');
      }
      if (got + piece.length > out.length) {
        var size = out.length;
        while (size < got + piece.length) {
          size <<= 1;
        }
        out = Uint8List(size)..setRange(0, got, out);
      }
      out.setRange(got, got + piece.length, piece);
      got += piece.length;
    }
    return out.length == count ? out : Uint8List.sublistView(out, 0, count);
  }

  Future<void> skip(int count) async {
    var left = count;
    while (left > 0) {
      final piece = await some(left);
      if (piece.isEmpty) {
        throw ArchiveException('tar: unexpected end of archive');
      }
      left -= piece.length;
    }
  }

  Future<void> cancel() => _it.cancel();
}

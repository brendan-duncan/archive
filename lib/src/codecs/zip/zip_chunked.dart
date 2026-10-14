import 'dart:async';
import 'dart:convert';

import '../../archive/archive_file.dart';
import '../../util/_pieces.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../../util/decode_guard.dart';
import '../zip_encoder.dart';
import '../zlib/deflate.dart';

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class ZipCodec {
  final int level;
  final String? password;
  final Encoding filenameEncoding;

  /// See [ZipChunkedEncoder.streamed]
  final bool streamed;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const ZipCodec(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true,
      this.autoClose = false});

  ZipEncoderTransformer get encoder => ZipEncoderTransformer(
      level: level,
      password: password,
      filenameEncoding: filenameEncoding,
      streamed: streamed,
      autoClose: autoClose);
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
const zipCodec = ZipCodec();

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class ZipEncoderTransformer
    extends StreamTransformerBase<ArchiveFile, List<int>> {
  final int level;
  final String? password;
  final Encoding filenameEncoding;
  final bool streamed;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const ZipEncoderTransformer(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true,
      this.autoClose = false});

  @override
  Stream<List<int>> bind(Stream<ArchiveFile> stream) => archiveStreamErrors(
      stream,
      (Stream<ArchiveFile> source) => cancellableStream<ArchiveFile, List<int>>(
          source, (input, signal) => _write(input, signal)));

  Stream<List<int>> _write(
      StreamIterator<ArchiveFile> input, CancelSignal signal) async* {
    final held = <List<int>>[];
    final encoder = ZipChunkedEncoder(Pieces(held),
        level: level,
        password: password,
        filenameEncoding: filenameEncoding,
        streamed: streamed);
    while (await input.moveNext()) {
      final entry = input.current;
      try {
        // Header first, then the content in pieces, so a reader gets the first
        // bytes before the entry is fully deflated. On the web the body is one
        // step
        final body = encoder.addHeader(entry);
        encoder.flush();
        while (held.isNotEmpty) {
          yield held.removeAt(0);
        }
        if (body == null) {
          continue;
        }
        try {
          while (body.step()) {
            while (held.isNotEmpty) {
              yield held.removeAt(0);
            }
          }
          body.finish();
          encoder.flush();
          while (held.isNotEmpty) {
            yield held.removeAt(0);
          }
        } finally {
          // A cancel stops us at one of the yields above, so finish never ran
          body.cancel();
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

/// Writes a zip archive to a [Sink] entry by entry. When [streamed] is
/// disabled, it buffers each entry to compute the CRC and sizes for the local
/// header, while [streamed], the default, writes them after the payload instead
class ZipChunkedEncoder {
  final Sink<List<int>> output;

  /// Deflates data directly into [output] and appends the CRC and sizes
  /// afterward. This keeps memory usage down to a single deflate buffer
  /// rather than the full entry size. Disable this to match the exact
  /// byte output of `ZipEncoder.encodeBytes`
  final bool streamed;

  ZipChunkedEncoder(this.output,
      {int level = DeflateLevel.bestSpeed,
      String? password,
      Encoding filenameEncoding = const Utf8Codec(),
      DateTime? modified,
      this.streamed = true})
      : _encoder = ZipEncoder(
            password: password,
            filenameEncoding: filenameEncoding,
            streamed: streamed) {
    _encoder.startEncode(_out, level: level, modified: modified);
  }

  final ZipEncoder _encoder;
  late final _out = SinkOutputStream(output);
  var _closed = false;

  /// With `autoClose`, adding same entry again writes entry as 0 bytes
  /// without error, since its `InputFileStream` is closed. Pass
  /// `autoClose: false` to add entry more than once
  void add(ArchiveFile entry, {bool autoClose = true}) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    _encoder.add(entry, autoClose: autoClose);
  }

  /// Writes [entry]'s local header and returns its body. Null if the entry is
  /// already written whole. The entry is not closed: call
  /// [ArchiveFile.closeSync] after its body is written
  ZipEntryBody? addHeader(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    return _encoder.addHeader(entry, autoClose: false);
  }

  /// SinkOutputStream holds up to 64 KiB, so without this finished entry
  /// waits in buffer until next entry arrives or archive closes
  void flush() => _out.flush();

  /// The central directory and the record that points at it, then the sink
  void close({String? comment = ''}) {
    if (_closed) {
      return;
    }
    _closed = true;
    _encoder.endEncode(comment: comment);
    output.close();
  }
}

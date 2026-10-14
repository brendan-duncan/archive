/// {@template archive.yield_codecs.decoder}
/// Example for .decoder:
///
/// ```dart
/// import 'package:archive/archive.dart';
/// import 'dart:io';
/// import 'package:path/path.dart' as p;
///
/// final request = await HttpClient()
///     .getUrl(Uri.parse('https://example.com/data.tar.zst'));
/// final HttpClientResponse response = await request.close();
///
/// await for (final TarEntry entry in response
///     // also available for xz/zstd/bzip2/tar
///     .transform(zstdCodec.decoder)
///     .transform(tarCodec.decoder)) {
///   final target = p.join('out', entry.name);
///   if (!p.isWithin('out', target)) continue; // `../` would escape out/
///   if (entry.type == TarEntryType.file) {
///     await File(target).create(recursive: true);
///     await entry.content.pipe(File(target).openWrite());
///   }
/// }
/// ```
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.converters.encoder}
/// Example for .encoder:
/// ```dart
/// import 'dart:io';
/// import 'package:archive/archive.dart';
///
/// final out = File('data.xz').openWrite();
/// await File('data')
///     .openRead()
///     // also available for xz/zstd/bzip2/tar/zip
///     .transform(xzCodec.encoder)
///     .pipe(out);
/// ```
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.yield_codecs.encoder}
/// Example for .encoder:
///
/// ```dart
/// Stream<ArchiveFile> filesOf(Directory dir) async* {
///   await for (final entity in dir.list(recursive: true)) {
///     if (entity is File) {
///       final input = InputFileStream(entity.path);
///       try {
///         yield ArchiveFile.stream(
///             p.relative(entity.path, from: dir.path), input);
///       } finally {
///         // Runs once the encoder has written the entry, or when it is
///         // cancelled
///         await input.close();
///       }
///     }
///   }
/// }
///
/// final upload =
///     await HttpClient().putUrl(Uri.parse('https://example.com/backup'));
/// upload.headers.contentType = ContentType('application', 'zstd');
/// await upload.addStream(filesOf(Directory('data'))
///      // also available for zip/tar
///     .transform(zipCodec.encoder) // Stream<ArchiveFile> -> Stream<List<int>>
///      // also available for zstd/xz/bzip2
///     .transform(zstdCodec.encoder));
/// final response = await upload.close();
/// ```
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.codecs.chunked_conversion}
/// ```dart
/// final file = File('out.bin').openWrite();
///             // also available for xz/zstd/bzip2
/// final sink = xzCodec.decoder.startChunkedConversion(file);
/// try {
///   sink..add(bytes)..close();
/// } catch (_) {
///   await file.close();
///   rethrow;
/// }
/// ```
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.codecs.without_on_done}
/// Please note that onDone
/// may never be called on failure, you have to listen for both onError and
/// onDone to identify the end of stream.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.codecs.general}
/// Codec for compressing and uncompressing data that arrives in pieces,
/// the way `transform` from `Stream<List<int>>` sends it.
///
/// Ideal for usage during network downloads/uploads without
/// creating temporary files
///
/// Behaviour is identical to `gzip` and `zlib` from `dart:io`, except  for
/// `TAR`, `ZIP` and codecs that are used with `MultithreadOptions`,
/// which only differ in closing the sink on failure.
///
/// `ZstdMultithreadOptions` is available only for `zstdCodec.encoder` and
/// `XZMultithreadOptions` for `xzCodec.decoder`.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.codecs.auto_close}
/// Closes each entry once it is written, the way `ZipEncoder.add` does. Off
/// by default, as it is on `ZipEncoder.encodeStream`: the entries are not
/// ours, and whoever opened a file closes it
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.codecs.not_converter}
/// Not a standard `dart:convert` `Codec` because it doesn't perform simple
/// byte-to-byte conversions, acting purely as a `StreamTransformer`.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.yield_codecs.one_at_time}
/// It reads one entry at a time and holds one entry's header rather than the
/// whole archive. Content has to be read before the loop moves on, the bytes
/// are gone once it does. What left unread is skipped.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_examples}
///
/// XZ decode example:
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
/// Zstd encode example:
/// ```dart
/// final input = InputFileStream('data.bin');
/// final output = OutputFileStream('data.bin.zst');
/// final completer = Completer<bool>();
/// ZstdEncoder(level: 6).encodeStream(input, output,
///     multithread: ZstdMultithreadOptions(
///       onDone: completer.complete,
///       onError: (error, _) => completer.completeError(error),
///       workers: 4,
///     ));
/// await completer.future;
/// await output.close();
/// await input.close();
/// ```
///
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_header}
/// Pass this to the the call to spread it over isolates. You cannot wait for an
/// isolate synchronously, so the call returns an empty result at once and the
/// real result goes to [onDone], error is placed inside the [onError] callback.
/// Without [onError] a failure goes to onDone as an empty list for
/// decodeBytes/encodeBytes, the same as an empty archive, or as false for
/// decodeStream/encodeStream.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.yield_codecs_multithreaded_example}
/// Zstd example:
/// ```dart
/// await File('data.bin')
///     .openRead()
///     .transform(ZstdCodec(
///       level: 6,
///       multithread: ZstdMultithreadOptions.converter(workers: 4),
///     ).encoder)
///     .pipe(File('data.bin.zst').openWrite());
/// ```
/// Xz example:
/// ```dart
/// await File('data.bin.xz')
///     .openRead()
///     .transform(XzCodec(
///       multithread: XZMultithreadOptions.converter(workers: 4),
///     ).decoder)
///     .pipe(File('data.bin').openWrite());
/// ```
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_workers}
/// At least 1. We clamp it to the block count and to the processor count.
/// More workers than cores costs memory yet does not work faster.
/// `memoryBudget` can still lower it
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_memory_budget}
/// Decides how many blocks to run at once. It applies on top of `workers`, even
/// when you set those. One worker always runs, regardless of how small this is.
/// Dart cannot ask the system how much memory is free, so a phone and a
/// workstation need different values here
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_memory_on_error}
/// Where a failure of the call goes. An argument field passed to the function
/// that cannot be honoured does not come here, it throws at the call
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.multithreaded_memory_on_done}
/// Where the result goes when the call has nowhere else to put it. A stream
/// converter carries its own end, so `transform` leaves this null
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.header_size_trust}
/// A header can claim any size. We believe anything under this value and
/// allocate up front, over it we grow the buffer as the bytes really arrive
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.decoder_callback}
/// [callback] gets every entry as soon as it is read, so each entry can be
/// written out before the next one is decoded
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.verify_throw_on_error}
/// `throwOnError` throws `ArchiveException` on damaged or cut data.
/// `verify` also checks checksums at a tiny cost of ~5-10% speed decrease
/// depending on archive file, and a mismatch throws
/// `ArchiveChecksumException`. `throwOnError` defaults to `verify`, so
/// `verify` alone throws too; pass `throwOnError: false` with it to have
/// failures reported without throwing.
/// Without `throwOnError`, decodeBytes returns partial data and decodeStream
/// returns false.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.archive_verify_throw_on_error}
/// `throwOnError` throws `ArchiveException` on damaged or cut data.
/// `verify` also checks checksums at a tiny cost of ~5-10% speed decrease
/// depending on archive file, and a mismatch throws
/// `ArchiveChecksumException`. `throwOnError` defaults to `verify`, so
/// `verify` alone throws too; pass `throwOnError: false` with it to have
/// failures reported without throwing.
/// Without `throwOnError`, returned archive holds entries read before damage,
/// and damaged entry may read as partial or empty data.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.xz.max_dictionary_size}
/// The largest LZMA2 dictionary an archive may declare. A block declaring
/// more is refused.
///
/// The dictionary is held in memory as the data decodes, even when
/// streaming, so this bounds the memory a decode takes. The default,
/// `xzDefaultMaxDictionarySize`, is four times the largest dictionary any
/// of xz's presets uses.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.decode_lazy}
/// Returns an [InputStream] that decompresses [input] as it is read.
///
/// Nothing is decoded until the returned stream is read, and only a window
/// of the decoded data is held in memory, so a multi-gigabyte archive can
/// be fed to another decoder, such as a tar decoder, without a temp file.
/// The stream is read forwards: see [InputDecodeStream] for what that
/// means. A malformed or truncated input throws an [ArchiveException] from
/// the read that runs into it.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.max_output_size.bytes}
/// With [maxOutputSize], an [ArchiveLimitException] is thrown as soon as the
/// decoded data would pass that many bytes, rather than decoding a small
/// input that expands without limit.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.max_output_size.stream}
/// With [maxOutputSize], an [ArchiveLimitException] is thrown as soon as more
/// than that many bytes would be written to [output], whatever
/// [throwOnError] is.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.xz.verify_default}
/// Unlike default decodeStream/decodeBytes, verify is on by default to match
/// gzip and zlib behaviour. Checks CRC or SHA-256 of every block.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.zstd.content_size}
/// Streamed frame has no Frame_Content_Size, so reader has to decode whole
/// frame to learn its size. Pass input length here to write that size
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.zstd.ultra}
/// Allows levels 20 to 22 when `contentSize` is not given, as `zstd --ultra`
/// does. Without it they are reduced to 19: with unknown size level 22 sizes
/// its tables for a 128 MB window and took 655 MB on 100 bytes of input,
/// where `zstd -22 --ultra` took 707 MB. With `contentSize` the tables follow
/// the input size and this has no effect.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.extract.allow_absolute_symlinks}
/// A symlink to an absolute path points outside [outputPath], so it is
/// skipped unless [allowAbsoluteSymlinks] is set
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.extract.max_size}
/// [maxSize] limits the total size of the files written. An entry that would
/// take it past that throws an [ArchiveLimitException] before it is written.
/// A zip entry is never decoded past the size the archive gives for it.
/// {@endtemplate}

/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------
/// ------------------------------------------------------------------------

/// {@template archive.extract.cut_tar}
/// A truncated tar entry is detected only if [archive] was decoded with
/// `throwOnError` or `verify`. Without them TarDecoder returns the bytes it
/// read as a complete file, and that file is extracted without an error.
/// {@endtemplate}

/// Must be after templates
library;

export '_zstd_sequences_html.dart'
    if (dart.library.isolate) '_zstd_sequences_io.dart'
    if (dart.library.js_util) '_zstd_sequences_html.dart'
    if (dart.library.js_interop) '_zstd_sequences_io.dart';
export 'zstd_sequences_base.dart' show ZstdSequencesException;

import 'archive_exception.dart';

_DecodeContext? _activeDecodeContext;

/// Runs [decode] under the `verify` and `throwOnError` rules shared by every
/// decoder: without `throwOnError` decoding errors are suppressed except
/// [ArchivePasswordException], [ArchiveMacException] and
/// [ArchiveLimitException], a checksum failure
/// is thrown as [ArchiveChecksumException] only with `verify` as well, and
/// callback errors propagate
bool guardDecode(
    String format, bool verify, bool throwOnError, bool Function() decode) {
  final strict = throwOnError;
  final context = _DecodeContext(_activeDecodeContext);
  _activeDecodeContext = context;
  try {
    if (decode()) {
      return true;
    }
    if (strict) {
      throw ArchiveException('Invalid $format data');
    }
    return false;
  } catch (error) {
    if (isDecodeCallbackError(error)) {
      rethrow;
    }
    if (error is CallbackFailure) {
      Error.throwWithStackTrace(error.error, error.stackTrace);
    }
    if (!isDecodeDataError(error)) {
      rethrow;
    }
    if (error is ArchivePasswordException ||
        error is ArchiveMacException ||
        error is ArchiveLimitException) {
      rethrow;
    }
    if (error is ArchiveChecksumException) {
      if (verify && throwOnError) {
        rethrow;
      }
      if (throwOnError) {
        throw ArchiveException(error.message);
      }
      return false;
    }
    if (error is ArchiveException) {
      if (strict) {
        rethrow;
      }
      return false;
    }
    if (strict) {
      throw ArchiveException('Invalid $format data: $error');
    }
    return false;
  } finally {
    _activeDecodeContext = context.parent;
  }
}

bool isDecodeCallbackError(Object error) =>
    _activeDecodeContext?.callbackErrors?.contains(error) ?? false;

bool isDecodeDataError(Object error) =>
    // Yes right now ArchiveException equals FormatException, but somebody
    // may accidentally change this in future and break everything, and
    // check is free
    error is ArchiveException ||
    // Just in case somebody cancels extending in future updates
    error is ArchiveChecksumException ||
    // Can not be here because this one is apart of above scope and should
    // be thrown regardless of flags
    // error is ArchivePasswordException ||
    error is FormatException ||
    error is RangeError ||
    error is TypeError;

Object archiveError(Object error, [String prefix = '']) =>
    isDecodeDataError(error) && error is! ArchiveException
        ? ArchiveException('$prefix$error')
        : error;

class _SourceError {
  final Object error;

  _SourceError(this.error);
}

Object sourceError(Object error) => error is _SourceError ? error.error : error;

Stream<T> archiveStreamErrors<S, T>(
        Stream<S> source, Stream<T> Function(Stream<S> source) convert) =>
    convert(source.handleError(
        (Object error, StackTrace stack) =>
            Error.throwWithStackTrace(_SourceError(error), stack))).handleError(
        (Object error, StackTrace stack) => Error.throwWithStackTrace(
            error is _SourceError ? error.error : archiveError(error), stack));

/// Wraps user callback run inside guardDecode, so its error keeps its type
/// instead of becoming ArchiveException.
/// Not used yet but useful if new features appear in package
void invokeDecodeCallback<T>(void Function(T) callback, T value) {
  try {
    callback(value);
  } catch (error) {
    for (var context = _activeDecodeContext;
        context != null;
        context = context.parent) {
      (context.callbackErrors ??= Set<Object>.identity()).add(error);
    }
    rethrow;
  }
}

class _DecodeContext {
  final _DecodeContext? parent;
  Set<Object>? callbackErrors;

  _DecodeContext(this.parent);
}

void throwIfStrict(ArchiveException error, bool verify, bool throwOnError) {
  if (error is ArchivePasswordException || error is ArchiveLimitException) {
    throw error;
  }
  if (error is ArchiveChecksumException && !verify) {
    if (throwOnError) {
      throw ArchiveException(error.message);
    }
    return;
  }
  if (throwOnError) {
    throw error;
  }
}

class CallbackFailure {
  final Object error;
  final StackTrace stackTrace;

  CallbackFailure(this.error, this.stackTrace);
}

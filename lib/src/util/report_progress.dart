import 'dart:async';

/// Calls [callback] with [value]. A progress listener must not stop the work
/// it listens to, so an exception from it goes to the zone
void reportProgress<T>(void Function(T value)? callback, T value) {
  if (callback == null) {
    return;
  }
  try {
    callback(value);
  } catch (error, stack) {
    Zone.current.handleUncaughtError(error, stack);
  }
}

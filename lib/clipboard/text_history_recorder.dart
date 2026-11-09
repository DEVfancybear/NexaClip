import 'text_history_store.dart';

/// Serializes clipboard events so database writes keep their observed order.
class TextHistoryRecorder {
  TextHistoryRecorder(this.store, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final TextHistoryStore store;
  final DateTime Function() _clock;
  Future<void> _pending = Future.value();
  Object? _writeError;
  StackTrace? _writeStack;

  /// Queues one observed clipboard value. Null and empty values are ignored.
  Future<void> record(String? text) {
    if (text == null || text.isEmpty) return Future.value();
    final timestamp = _clock();
    final result = _pending.then((_) => store.add(text, timestamp));
    // A failed write is reported to its caller, but does not stop later writes.
    _pending =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      _writeError ??= error;
      _writeStack ??= stack;
    });
    return result;
  }

  /// Waits for all writes that were queued before this call.
  Future<void> flush() async {
    await _pending;
    final error = _writeError;
    final stack = _writeStack;
    _writeError = null;
    _writeStack = null;
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }
}

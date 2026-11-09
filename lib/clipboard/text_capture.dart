import 'dart:async';

import 'text_history_recorder.dart';

/// Receives text events from a platform source while capture is active.
class TextCapture {
  TextCapture(this._recorder, {required this.onError, this.onRecorded});

  final TextHistoryRecorder _recorder;
  final void Function(Object error, StackTrace stackTrace) onError;
  final void Function()? onRecorded;
  StreamSubscription<String?>? _subscription;

  bool get isActive => _subscription != null;

  void start(Stream<String?> events) {
    if (isActive) throw StateError('Capture is already active');
    _subscription = events.listen(
      (text) {
        _recorder.record(text).then((_) {
          if (text != null && text.isNotEmpty) onRecorded?.call();
        }).catchError(onError);
      },
      onError: onError,
    );
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _recorder.flush();
  }
}

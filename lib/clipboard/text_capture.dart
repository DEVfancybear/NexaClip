import 'dart:async';

import 'text_history_recorder.dart';
import 'windows_clipboard_source.dart';

/// Receives text events from a platform source while capture is active.
class TextCapture {
  TextCapture(this._recorder, {required this.onError, this.onRecorded});

  final TextHistoryRecorder _recorder;
  final void Function(Object error, StackTrace stackTrace) onError;
  final void Function()? onRecorded;
  StreamSubscription<Object?>? _subscription;

  bool get isActive => _subscription != null;

  void _reportError(Object error, StackTrace stack) {
    try {
      onError(error, stack);
    } catch (_) {
      // A diagnostic callback must not interrupt capture or notification.
    }
  }

  void start(Stream<Object?> events) {
    if (isActive) throw StateError('Capture is already active');
    _subscription = events.listen(
      (value) {
        if (value is ClipboardSnapshot) {
          final warnings = <Object>[if (value.warning != null) value.warning!];
          void report([Object? error, StackTrace? stack]) {
            if (error != null) warnings.add(error);
            if (warnings.isNotEmpty) {
              _reportError(
                  StateError(warnings.join('; ')), stack ?? StackTrace.current);
            }
          }

          final recording = _recorder
              .record(value.value,
                  onRejected: () => warnings.add(StateError(
                      'Ảnh PNG không hợp lệ, vượt giới hạn hoặc hàng đợi ảnh đã đầy; văn bản đi kèm vẫn có thể được lưu.')),
                  onFailure: (error, stack) => report(error, stack),
                  onComplete: (recorded) {
                    report();
                    if (recorded) {
                      try {
                        onRecorded?.call();
                      } catch (error, stack) {
                        _reportError(error, stack);
                      }
                    }
                  })
              .then<void>((_) {}, onError: (Object _, StackTrace __) {});
          if (value is AcknowledgedClipboardSnapshot) {
            value.acknowledgeAfter(recording);
          }
          return;
        }
        _recorder.record(value, onFailure: onError).then<void>((recorded) {
          if (recorded) {
            try {
              onRecorded?.call();
            } catch (error, stack) {
              _reportError(error, stack);
            }
          }
        }, onError: (Object _, StackTrace __) {});
      },
      onError: (Object error, StackTrace stack) {
        _recorder.enqueueDiagnostic(() => onError(error, stack));
      },
    );
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _recorder.flush();
  }
}

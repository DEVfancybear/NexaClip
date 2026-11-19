import 'dart:async';

import 'text_capture.dart';
import 'text_history_recorder.dart';
import 'text_history_store.dart';
import 'windows_clipboard_source.dart';

/// Listener registration and draining queued writes both failed.
class HistoryStartException implements Exception {
  HistoryStartException(this.listenerError, this.writeError);

  final Object listenerError;
  final Object writeError;

  @override
  String toString() =>
      'Listener start failed: $listenerError; write failed: $writeError';
}

/// Both listener cleanup and draining queued writes failed.
class HistoryStopException implements Exception {
  HistoryStopException(this.listenerError, this.writeError);

  final Object listenerError;
  final Object writeError;

  @override
  String toString() =>
      'Listener stop failed: $listenerError; write failed: $writeError';
}

/// Session shutdown and subsequent source disposal both failed.
class HistoryDisposeException implements Exception {
  HistoryDisposeException(this.stopError, this.disposeError);

  final Object stopError;
  final Object disposeError;

  @override
  String toString() =>
      'Session stop failed: $stopError; source disposal failed: $disposeError';
}

/// Owns the clipboard listener and the queued writes for one capture session.
class HistorySession {
  HistorySession({
    required TextHistoryStore store,
    required WindowsClipboardSource source,
    required void Function(Object, StackTrace) onError,
    void Function()? onRecorded,
  })  : _source = source,
        _capture = TextCapture(
            TextHistoryRecorder(store, onImageRejected: () {
              onError(
                  StateError(
                      'Ảnh PNG không hợp lệ, vượt giới hạn hoặc hàng đợi ảnh đã đầy; văn bản đi kèm vẫn có thể được lưu.'),
                  StackTrace.current);
            }),
            onError: onError,
            onRecorded: onRecorded) {
    _urgentSubscription = _source.urgentDiagnostics.listen((error) {
      if (_disposed || !_capture.isActive) return;
      try {
        onError(error, StackTrace.current);
      } catch (_) {
        // A UI callback must not affect capture or channel replies.
      }
    });
  }

  final WindowsClipboardSource _source;
  final TextCapture _capture;
  late final StreamSubscription<Object> _urgentSubscription;
  bool _active = false;
  bool _disposed = false;
  Future<void>? _disposeResult;
  Future<void> _pending = Future.value();

  bool get isActive => _capture.isActive;

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> start() {
    if (_disposed) return Future.error(StateError('Session is disposed'));
    return _enqueue(() async {
      if (_capture.isActive) throw StateError('Session is already active');
      // A failed stop leaves the native listener registered; retry cleanup
      // before starting another capture subscription.
      if (_active) await _stop();
      _capture.start(_source.snapshots);
      _source.requireRecordingAcknowledgement = true;
      // A failed start reply does not prove native registration failed.
      _active = true;
      try {
        await _source.start();
      } catch (listenerError, listenerStack) {
        Object startError = listenerError;
        try {
          await _source.stop();
          _active = false;
        } catch (cleanupError) {
          startError = HistoryStopException(listenerError, cleanupError);
        }
        try {
          await _capture.stop();
        } catch (writeError, writeStack) {
          Error.throwWithStackTrace(
              HistoryStartException(startError, writeError), writeStack);
        }
        Error.throwWithStackTrace(startError, listenerStack);
      }
    });
  }

  Future<void> _stop() async {
    if (!_active) return;
    Object? listenerError;
    StackTrace? listenerStack;
    try {
      await _source.stop();
      _active = false;
    } catch (error, stack) {
      listenerError = error;
      listenerStack = stack;
    }
    try {
      await _capture.stop();
    } catch (writeError, writeStack) {
      if (listenerError != null) {
        Error.throwWithStackTrace(
            HistoryStopException(listenerError, writeError), writeStack);
      }
      Error.throwWithStackTrace(writeError, writeStack);
    }
    if (listenerError != null) {
      Error.throwWithStackTrace(listenerError, listenerStack!);
    }
  }

  Future<void> stop() => _enqueue(_stop);

  Future<void> dispose() {
    if (_disposeResult case final result?) return result;
    _disposed = true;
    final result = _enqueue(() async {
      Object? stopError;
      StackTrace? stopStack;
      try {
        await _stop();
      } catch (error, stack) {
        stopError = error;
        stopStack = stack;
      }
      await _urgentSubscription.cancel();
      try {
        await _source.dispose();
      } catch (error, stack) {
        if (stopError != null) {
          Error.throwWithStackTrace(
              HistoryDisposeException(stopError, error), stack);
        }
        Error.throwWithStackTrace(error, stack);
      }
      if (stopError != null) Error.throwWithStackTrace(stopError, stopStack!);
    });
    _disposeResult = result;
    return result;
  }
}

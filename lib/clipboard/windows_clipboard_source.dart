import 'dart:async';

import 'package:flutter/services.dart';

import 'png_validation.dart';
import 'text_history_recorder.dart';

class ClipboardSnapshot {
  const ClipboardSnapshot(this.value, {this.warning});
  final Object? value;
  final Object? warning;
}

/// A snapshot whose channel response waits for the recorder to finish.
class AcknowledgedClipboardSnapshot extends ClipboardSnapshot {
  AcknowledgedClipboardSnapshot(super.value, {super.warning});

  Future<void>? _processing;
  void acknowledgeAfter(Future<void> processing) {
    if (_processing != null) throw StateError('Snapshot already claimed');
    _processing = processing;
  }
}

class ClipboardCaptureFailure implements Exception {
  @override
  String toString() =>
      'Theo dõi clipboard đã dừng do lỗi hàng đợi; một số thay đổi có thể không được lưu.';
}

/// Emits text or PNG bytes reported by the Windows clipboard channel.
class WindowsClipboardSource {
  WindowsClipboardSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('nexaclip/clipboard');

  static int _lastGeneration = 0;
  static const int _maxGeneration = 0x7fffffffffffffff;

  final MethodChannel _channel;
  final StreamController<Object?> _events = StreamController.broadcast();
  final StreamController<Object> _urgentDiagnostics =
      StreamController.broadcast(sync: true);
  int? _generation;
  bool _active = false;
  bool _accepting = false;
  Future<void>? _stopping;
  Future<void>? _starting;

  final StreamController<ClipboardSnapshot> _snapshots =
      StreamController.broadcast(sync: true);
  Stream<Object?> get events => _events.stream;
  Stream<ClipboardSnapshot> get snapshots => _snapshots.stream;
  Stream<Object> get urgentDiagnostics => _urgentDiagnostics.stream;

  // A session enables this before registering the native listener. Observers
  // using the source alone do not take ownership of persistence.
  bool requireRecordingAcknowledgement = false;

  Future<void> _sendSnapshot(Object? value, {Object? warning}) async {
    if (!requireRecordingAcknowledgement) {
      _snapshots.add(ClipboardSnapshot(value, warning: warning));
      return;
    }
    final snapshot = AcknowledgedClipboardSnapshot(value, warning: warning);
    _snapshots.add(snapshot);
    final processing = snapshot._processing;
    if (processing == null) {
      throw StateError('No recorder accepted the snapshot');
    }
    await processing;
  }

  Future<void> start() {
    if (_active || _stopping != null) {
      return Future.error(
          StateError('Clipboard source is already active or stopping'));
    }
    if (_lastGeneration == _maxGeneration) {
      return Future.error(StateError('Clipboard generation exhausted'));
    }
    final generation = ++_lastGeneration;
    _generation = generation;
    final completion = Completer<void>();
    _starting = completion.future;
    _channel.setMethodCallHandler(_handleCall);
    _active = true;
    _accepting = true;
    () async {
      try {
        await _channel.invokeMethod<void>('start', generation);
        completion.complete();
      } catch (error, stack) {
        // Registration may have succeeded even if the channel reply failed.
        // Keep admitting snapshots until cleanup drains or fails.
        completion.completeError(error, stack);
      } finally {
        _starting = null;
      }
    }();
    return completion.future;
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method == 'captureFailed') {
      if (_accepting &&
          !_urgentDiagnostics.isClosed &&
          call.arguments is int &&
          call.arguments == _generation) {
        _urgentDiagnostics.add(ClipboardCaptureFailure());
      }
      return;
    }
    if (call.method != 'changed') throw MissingPluginException();
    if (!_accepting || _events.isClosed) {
      throw StateError('Clipboard source is not accepting snapshots');
    }
    final value = call.arguments;
    if (value is Map) {
      final textTooLarge = value['textTooLarge'] == true;
      final png = value['png'];
      final fallback = value['fallbackPng'];
      final primaryValid =
          png is Uint8List && png.isNotEmpty && png.length <= maxPngBytes;
      final fallbackValid = fallback is Uint8List &&
          fallback.isNotEmpty &&
          fallback.length <= maxPngBytes;
      final pngRejected = value['pngRejected'] == true ||
          (!fallbackValid && png is Uint8List && !primaryValid);
      Object? warning;
      if (textTooLarge && pngRejected) {
        warning = StateError(
            'Văn bản clipboard vượt 1 MiB UTF-8 nên không được lưu; không thể nhận ảnh PNG từ clipboard.');
      } else if (textTooLarge) {
        warning = StateError(
            'Văn bản clipboard vượt 1 MiB UTF-8 nên không được lưu; ảnh hợp lệ vẫn có thể được lưu.');
      } else if (pngRejected) {
        warning = StateError(
            'Không thể nhận ảnh PNG từ clipboard; văn bản đi kèm vẫn có thể được lưu.');
      }
      if (value['fallbackUnavailable'] == true) {
        const unavailable =
            'Không thể xử lý ảnh dự phòng; ảnh PNG gốc vẫn có thể được lưu.';
        warning = StateError(
            warning == null ? unavailable : '$warning; $unavailable');
      }
      if (value['captureDropped'] == true) {
        final dropped =
            'Một hoặc nhiều thay đổi clipboard không được lưu vì hàng đợi đầy.';
        warning = StateError(warning == null ? dropped : '$warning; $dropped');
      }
      final text = value['text'];
      Object? payload;
      if (primaryValid || fallbackValid) {
        final primary = primaryValid ? png : fallback;
        payload = ClipboardImageWithText(
            Uint8List.fromList(primary as Uint8List),
            text is String ? text : null,
            fallbackImage: primaryValid && fallbackValid
                ? Uint8List.fromList(fallback)
                : null);
      } else if (text is String) {
        payload = text;
      }
      if (warning != null) _events.addError(warning);
      if (payload != null) _events.add(payload);
      if (payload != null || warning != null) {
        await _sendSnapshot(payload, warning: warning);
      }
    } else if (value is String) {
      _events.add(value);
      await _sendSnapshot(value);
    } else if (value is Uint8List) {
      if (value.isEmpty || value.length > maxPngBytes) {
        final warning = StateError('Không thể nhận ảnh PNG từ clipboard.');
        _events.addError(warning);
        await _sendSnapshot(null, warning: warning);
      } else {
        final bytes = Uint8List.fromList(value);
        _events.add(bytes);
        await _sendSnapshot(bytes);
      }
    }
  }

  Future<void> stop() {
    if (_stopping case final pending?) return pending;
    if (!_active) return Future.value();
    final completion = Completer<void>();
    _stopping = completion.future;
    () async {
      try {
        final starting = _starting;
        if (starting != null) {
          try {
            await starting;
          } catch (_) {
            // The native registration outcome is unknown; still stop it.
          }
        }
        await _channel.invokeMethod<void>('stop');
        _active = false;
        _channel.setMethodCallHandler(null);
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _accepting = false;
        _generation = null;
        _stopping = null;
      }
    }();
    return completion.future;
  }

  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      _channel.setMethodCallHandler(null);
      await _events.close();
      await _snapshots.close();
      await _urgentDiagnostics.close();
    }
  }
}
